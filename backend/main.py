"""Backend de l'app fictive « Carnet ».

Le code AWS est celui d'une vraie application : boto3 sans aucun réglage propre à
l'émulateur. Seules les variables d'environnement (scripts/env.sh) le font pointer
sur AWS Emulator plutôt que sur AWS.

Briques utilisées : Cognito (connexion, jetons), Secrets Manager (mot de passe de la
base), RDS PostgreSQL (notes), ElastiCache (cache de la liste), S3 (export),
SQS (événements), CloudWatch Logs (journal).
"""
import json
import os
import ssl
import time
import uuid

import boto3
import jwt
import psycopg
import redis
from botocore.exceptions import ClientError
from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel

REGION = os.environ.get("AWS_REGION", "us-east-1")
ENDPOINT = os.environ.get("AWS_ENDPOINT_URL")  # défini seulement face à l'émulateur
POOL_ID = os.environ["COGNITO_POOL_ID"]
CLIENT_ID = os.environ["COGNITO_CLIENT_ID"]
DB_INSTANCE_ID = os.environ["DB_INSTANCE_ID"]
DB_NAME = os.environ["DB_NAME"]
DB_SECRET_ID = os.environ["DB_SECRET_ID"]
CACHE_CLUSTER_ID = os.environ["CACHE_CLUSTER_ID"]
REDIS_FALLBACK_URL = os.environ.get("REDIS_FALLBACK_URL", "redis://127.0.0.1:6379/0")
BUCKET = os.environ["BUCKET"]
QUEUE_URL = os.environ["QUEUE_URL"]
LOG_GROUP = os.environ["LOG_GROUP"]
LOG_STREAM = f"backend-{int(time.time())}"

cognito = boto3.client("cognito-idp")
secrets = boto3.client("secretsmanager")
rds = boto3.client("rds")
elasticache = boto3.client("elasticache")
s3 = boto3.client("s3")
sqs = boto3.client("sqs")
logs = boto3.client("logs")

# Sur AWS, l'émetteur des jetons est cognito-idp.<région>.amazonaws.com ;
# l'émulateur signe avec sa propre adresse. C'est le seul endroit où le code le sait.
ISSUER = f"{ENDPOINT}/{POOL_ID}" if ENDPOINT else f"https://cognito-idp.{REGION}.amazonaws.com/{POOL_ID}"
_ssl = ssl.create_default_context(cafile=os.environ.get("AWS_CA_BUNDLE"))
jwks = jwt.PyJWKClient(f"{ISSUER}/.well-known/jwks.json", ssl_context=_ssl)

app = FastAPI(title="Carnet")
state: dict = {"cache": None, "cache_source": None, "db": None}


# ------------------------------------------------------------------ dépendances
def db():
    """Connexion PostgreSQL : endpoint lu dans RDS, mot de passe lu dans Secrets Manager."""
    if state["db"] is None or state["db"].closed:
        cred = json.loads(secrets.get_secret_value(SecretId=DB_SECRET_ID)["SecretString"])
        ep = rds.describe_db_instances(DBInstanceIdentifier=DB_INSTANCE_ID)["DBInstances"][0]["Endpoint"]
        state["db"] = psycopg.connect(
            host=ep["Address"], port=ep["Port"], dbname=DB_NAME,
            user=cred["username"], password=cred["password"], connect_timeout=5, autocommit=True,
        )
        # SQL volontairement portable : pas de serial, ni now(), ni gen_random_uuid().
        state["db"].execute(
            "create table if not exists notes (id text primary key, auteur text not null, "
            "titre text not null, texte text, cree_le timestamp default current_timestamp)"
        )
    return state["db"]


def cache():
    """Redis : endpoint ElastiCache s'il répond au PING, sinon le Redis local de secours."""
    if state["cache"] is None:
        node = elasticache.describe_cache_clusters(
            CacheClusterId=CACHE_CLUSTER_ID, ShowCacheNodeInfo=True
        )["CacheClusters"][0]["CacheNodes"][0]["Endpoint"]
        # protocol=2 : le Redis émulé ne parle pas RESP3, que redis-py 8 négocie par défaut.
        client = redis.Redis(host=node["Address"], port=node["Port"], protocol=2,
                             socket_timeout=2, socket_connect_timeout=2, decode_responses=True)
        source = "elasticache"
        try:
            client.ping()
        except (redis.RedisError, OSError):
            client = redis.Redis.from_url(REDIS_FALLBACK_URL, socket_timeout=2, decode_responses=True)
            source = "redis local (endpoint ElastiCache injoignable)"
        state["cache"], state["cache_source"] = client, source
    return state["cache"]


def journal(message: str, **champs):
    try:
        if not state.get("flux"):
            logs.create_log_stream(logGroupName=LOG_GROUP, logStreamName=LOG_STREAM)
            state["flux"] = True
        logs.put_log_events(
            logGroupName=LOG_GROUP, logStreamName=LOG_STREAM,
            logEvents=[{"timestamp": int(time.time() * 1000), "message": json.dumps({"msg": message, **champs})}],
        )
    except ClientError:
        pass  # un journal en panne ne doit pas casser l'appel


def utilisateur(authorization: str = Header(default="")) -> str:
    """Vérifie le jeton d'accès Cognito (signature RS256 via JWKS, émetteur, client)."""
    token = authorization.removeprefix("Bearer ").strip()
    try:
        cle = jwks.get_signing_key_from_jwt(token).key
        claims = jwt.decode(token, cle, algorithms=["RS256"], issuer=ISSUER, options={"verify_aud": False})
        if claims.get("token_use") != "access" or claims.get("client_id") != CLIENT_ID:
            raise jwt.InvalidTokenError("jeton inattendu")
    except jwt.PyJWTError as e:
        raise HTTPException(401, f"Jeton invalide : {e}")
    return claims.get("username") or claims["sub"]


# ------------------------------------------------------------------ API
class Identifiants(BaseModel):
    email: str
    mot_de_passe: str


class NouvelleNote(BaseModel):
    titre: str
    texte: str = ""


@app.post("/api/connexion")
def connexion(ident: Identifiants):
    try:
        r = cognito.initiate_auth(
            ClientId=CLIENT_ID, AuthFlow="USER_PASSWORD_AUTH",
            AuthParameters={"USERNAME": ident.email, "PASSWORD": ident.mot_de_passe},
        )
    except ClientError as e:
        raise HTTPException(401, e.response["Error"]["Message"])
    journal("connexion", email=ident.email)
    return {"jeton": r["AuthenticationResult"]["AccessToken"], "email": ident.email}


@app.get("/api/notes")
def lister(qui: str = Depends(utilisateur)):
    cle = f"notes:{qui}"
    try:
        if (en_cache := cache().get(cle)) is not None:
            return {"notes": json.loads(en_cache), "source": "cache"}
    except redis.RedisError:
        pass
    lignes = db().execute(
        "select id, titre, texte, cree_le from notes where auteur = %s order by cree_le desc, id", (qui,)
    ).fetchall()
    notes = [{"id": i, "titre": t, "texte": x, "cree_le": str(c)} for i, t, x, c in lignes]
    try:
        cache().set(cle, json.dumps(notes), ex=30)
    except redis.RedisError:
        pass
    return {"notes": notes, "source": "base"}


@app.post("/api/notes", status_code=201)
def creer(note: NouvelleNote, qui: str = Depends(utilisateur)):
    ident = str(uuid.uuid4())
    db().execute("insert into notes (id, auteur, titre, texte) values (%s, %s, %s, %s)",
                 (ident, qui, note.titre, note.texte))
    s3.put_object(Bucket=BUCKET, Key=f"notes/{qui}/{ident}.json",
                  Body=json.dumps({"id": ident, **note.model_dump()}), ContentType="application/json")
    sqs.send_message(QueueUrl=QUEUE_URL, MessageBody=json.dumps({"type": "note.creee", "id": ident}))
    try:
        cache().delete(f"notes:{qui}")
    except redis.RedisError:
        pass
    journal("note.creee", id=ident, auteur=qui)
    return {"id": ident}


@app.get("/api/notes/{ident}/export")
def exporter(ident: str, qui: str = Depends(utilisateur)):
    url = s3.generate_presigned_url("get_object", Params={"Bucket": BUCKET, "Key": f"notes/{qui}/{ident}.json"}, ExpiresIn=60)
    return {"url": url}


@app.get("/api/health")
def sante():
    """État de chaque brique, affiché par le front."""
    def essai(nom, fn):
        try:
            return {"brique": nom, "ok": True, "detail": str(fn() or "")}
        except Exception as e:  # on veut le message, quelle que soit la brique
            return {"brique": nom, "ok": False, "detail": f"{type(e).__name__}: {e}"[:200]}

    return {"briques": [
        essai("Cognito", lambda: cognito.describe_user_pool(UserPoolId=POOL_ID)["UserPool"]["Name"]),
        essai("Secrets Manager", lambda: secrets.describe_secret(SecretId=DB_SECRET_ID)["Name"]),
        essai("RDS PostgreSQL", lambda: db().execute("select count(*) from notes").fetchone()[0].__str__() + " note(s)"),
        essai("ElastiCache", lambda: (cache().ping(), state["cache_source"])[1]),
        essai("S3", lambda: s3.head_bucket(Bucket=BUCKET) and BUCKET),
        essai("SQS", lambda: sqs.get_queue_attributes(QueueUrl=QUEUE_URL, AttributeNames=["ApproximateNumberOfMessages"])
              ["Attributes"]["ApproximateNumberOfMessages"] + " message(s) en file"),
        essai("CloudWatch Logs", lambda: logs.describe_log_groups(logGroupNamePrefix=LOG_GROUP)["logGroups"][0]["logGroupName"]),
    ]}
