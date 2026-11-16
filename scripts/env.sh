# À charger avec :  source scripts/env.sh
# Pointe la CLI AWS et les SDK sur l'émulateur local (aucun compte AWS requis).

EMULATOR_PORT="${EMULATOR_PORT:-9297}"
EMULATOR_HOME="${EMULATOR_HOME:-$HOME/.aws/emulator/$EMULATOR_PORT}"

export AWS_ENDPOINT_URL="https://127.0.0.1:${EMULATOR_PORT}"
export AWS_SHARED_CREDENTIALS_FILE="${EMULATOR_HOME}/emulator_credentials"
export AWS_CONFIG_FILE="${EMULATOR_HOME}/config"
export AWS_CA_BUNDLE="${EMULATOR_HOME}/ca.pem"
export AWS_EC2_METADATA_DISABLED=true
export AWS_DISABLE_HOST_PREFIX_INJECTION=true
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
export AWS_PAGER=""
# L'émulateur est local : ne jamais passer par un proxy d'entreprise.
export NO_PROXY="127.0.0.1,localhost${NO_PROXY:+,$NO_PROXY}"
export no_proxy="$NO_PROXY"
# Les vrais identifiants AWS n'ont rien à faire dans cet environnement.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE

if [ ! -f "$AWS_SHARED_CREDENTIALS_FILE" ]; then
  echo "Émulateur introuvable (${EMULATOR_HOME}). Lance d'abord : aws-emulator -t off" >&2
fi
