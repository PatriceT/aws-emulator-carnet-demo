import { useCallback, useEffect, useState } from "react";

async function api(chemin, { jeton, ...options } = {}) {
  const r = await fetch(`/api${chemin}`, {
    ...options,
    headers: {
      "content-type": "application/json",
      ...(jeton ? { authorization: `Bearer ${jeton}` } : {}),
    },
  });
  const corps = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(corps.detail || `Erreur ${r.status}`);
  return corps;
}

function Connexion({ onConnecte }) {
  const [email, setEmail] = useState("alice@example.com");
  const [motDePasse, setMotDePasse] = useState("Demo-Pass-123!");
  const [erreur, setErreur] = useState("");

  async function envoyer(e) {
    e.preventDefault();
    setErreur("");
    try {
      onConnecte(await api("/connexion", {
        method: "POST",
        body: JSON.stringify({ email, mot_de_passe: motDePasse }),
      }));
    } catch (err) {
      setErreur(err.message);
    }
  }

  return (
    <form className="carte" onSubmit={envoyer}>
      <h2>Connexion</h2>
      <p className="aide">Authentification par Amazon Cognito.</p>
      <label>E-mail<input value={email} onChange={(e) => setEmail(e.target.value)} /></label>
      <label>Mot de passe
        <input type="password" value={motDePasse} onChange={(e) => setMotDePasse(e.target.value)} />
      </label>
      {erreur && <p className="erreur">{erreur}</p>}
      <button>Se connecter</button>
    </form>
  );
}

function Notes({ session, onDeconnecte }) {
  const [notes, setNotes] = useState([]);
  const [source, setSource] = useState("");
  const [titre, setTitre] = useState("");
  const [texte, setTexte] = useState("");
  const [erreur, setErreur] = useState("");

  const charger = useCallback(async () => {
    try {
      const r = await api("/notes", { jeton: session.jeton });
      setNotes(r.notes);
      setSource(r.source);
    } catch (err) {
      setErreur(err.message);
    }
  }, [session.jeton]);

  useEffect(() => { charger(); }, [charger]);

  async function ajouter(e) {
    e.preventDefault();
    if (!titre.trim()) return;
    try {
      await api("/notes", { method: "POST", jeton: session.jeton, body: JSON.stringify({ titre, texte }) });
      setTitre("");
      setTexte("");
      charger();
    } catch (err) {
      setErreur(err.message);
    }
  }

  async function exporter(id) {
    const { url } = await api(`/notes/${id}/export`, { jeton: session.jeton });
    window.open(url, "_blank");
  }

  return (
    <section className="carte">
      <header className="ligne">
        <h2>Mes notes</h2>
        <button className="discret" onClick={onDeconnecte}>Déconnexion ({session.email})</button>
      </header>
      <form className="ajout" onSubmit={ajouter}>
        <input placeholder="Titre" value={titre} onChange={(e) => setTitre(e.target.value)} />
        <textarea placeholder="Texte" rows="2" value={texte} onChange={(e) => setTexte(e.target.value)} />
        <button>Ajouter</button>
      </form>
      {erreur && <p className="erreur">{erreur}</p>}
      <p className="aide">
        Liste lue depuis : <strong>{source === "cache" ? "le cache (ElastiCache)" : "la base (RDS PostgreSQL)"}</strong>{" "}
        <button className="discret" onClick={charger}>Recharger</button>
      </p>
      <ul className="notes">
        {notes.map((n) => (
          <li key={n.id}>
            <div><strong>{n.titre}</strong><span className="date">{n.cree_le}</span></div>
            {n.texte && <p>{n.texte}</p>}
            <button className="discret" onClick={() => exporter(n.id)}>Export S3 (URL présignée)</button>
          </li>
        ))}
        {notes.length === 0 && <li className="aide">Aucune note pour l'instant.</li>}
      </ul>
    </section>
  );
}

function Briques() {
  const [briques, setBriques] = useState(null);
  const charger = () => api("/health").then((r) => setBriques(r.briques)).catch(() => setBriques([]));
  useEffect(() => { charger(); }, []);

  return (
    <section className="carte">
      <header className="ligne">
        <h2>Briques AWS</h2>
        <button className="discret" onClick={charger}>Rafraîchir</button>
      </header>
      {briques === null && <p className="aide">Vérification…</p>}
      {briques?.length === 0 && <p className="erreur">Backend injoignable.</p>}
      <ul className="briques">
        {briques?.map((b) => (
          <li key={b.brique}>
            <span className={b.ok ? "pastille ok" : "pastille ko"} />
            <strong>{b.brique}</strong>
            <span className="detail">{b.detail}</span>
          </li>
        ))}
      </ul>
    </section>
  );
}

export default function App() {
  const [session, setSession] = useState(null);
  return (
    <main>
      <h1>Carnet</h1>
      <p className="sous-titre">App fictive pour tester AWS Emulator : React, Python, Cognito, RDS, ElastiCache, S3, SQS.</p>
      {session ? <Notes session={session} onDeconnecte={() => setSession(null)} /> : <Connexion onConnecte={setSession} />}
      <Briques />
    </main>
  );
}
