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
