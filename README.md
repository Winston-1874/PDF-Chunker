# RAG Configurator — PDF Chunker

Application web FastAPI pour configurer le chunking de textes juridiques en vue d'une utilisation RAG.

## Fonctionnalités

- **Projets** : architecture par projet (un projet = un texte juridique)
- **Upload PDF** : conversion PDF → Markdown via `pymupdf4llm`, avec plage de pages optionnelle
- **Chunking configurable** :
  - Règles de suppression (regex)
  - Règles de découpage (regex, le séparateur est conservé en tête de chunk)
  - Taille max de chunk (chars) avec marqueurs de troncature
- **Préfixes de contexte** : règles regex → label `[Préfixe]` ajouté en tête des chunks correspondants
- **Labels manuels** : possibilité d'assigner manuellement un préfixe aux chunks non résolus
- **Presets** : sauvegarde/chargement de configurations de règles
- **Exports** : raw.md, chunks.md, ZIP de chunks individuels, config JSON

## Stack

- Backend : FastAPI + Uvicorn
- Conversion PDF : PyMuPDF / pymupdf4llm
- Auth : cookie signé (itsdangerous)
- Templates : Jinja2

## Lancement local

```bash
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
APP_PASSWORD=monmotdepasse SECRET_KEY=maclef uvicorn main:app --reload --port 8765
```

Accéder à : http://localhost:8765

## Déploiement serveur

Utiliser `deploy.sh` (installe le service systemd sur `/opt/pdf-chunker`).
