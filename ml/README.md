# `ml/` — Pipeline de modèles Core ML (spec §29A)

> ## ⛔ ÉTAT AU 11 AOÛT 2026 : AUCUN MODÈLE N'EXISTE — JALON 11 NON TERMINÉ
>
> - **Aucun modèle n'est entraîné.** Aucun poids, aucun checkpoint, aucun corpus.
> - **Aucun modèle n'est embarqué dans la cible iOS.** Aucun `.mlpackage`, aucun `.mlmodelc`.
> - **Aucune donnée d'entraînement n'est présente dans ce dépôt**, et aucune licence de corpus n'a été validée.
> - **Aucun code d'entraînement Python n'a été écrit** (hors périmètre du travail réalisé).
> - Ce dossier ne contient donc que de la **documentation** : la structure attendue et les règles à respecter le jour
>   où un vrai modèle sera produit.
>
> C'est la position honnête exigée par le **§29A « Interdiction »** :
> « L'agent de programmation ne doit pas prétendre avoir créé un modèle intelligent en ajoutant des règles aléatoires
> ou un fichier Core ML vide. En l'absence de modèle entraîné, il implémente le protocole, le fallback et les tests,
> puis marque clairement le jalon avancé comme non terminé. »
>
> **Ce qui EST livré côté iOS** (le socle, pas l'intelligence) :
>
> | Fichier | Rôle |
> |---|---|
> | `App/Services/MusicAnalysis/BeatActivationModel.swift` | Protocole §19.2 verbatim + types d'entrée/sortie minimaux |
> | `App/Services/MusicAnalysis/CoreMLModelRegistry.swift` | Recherche d'un modèle embarqué → **`nil` aujourd'hui**, version §61 → **`nil`** |
> | `App/Services/MusicAnalysis/HybridMusicAnalyzer.swift` | Point de branchement niveau B ; **délègue intégralement** au moteur déterministe |
> | `Tests/Unit/HybridAnalyzerFallbackTests.swift` | Preuve du fallback §86 : résultat identique au moteur déterministe |
>
> Le moteur hybride **n'est pas câblé dans `AppEnvironment`** : l'application utilise toujours
> `DeterministicMusicAnalyzer`. Aucun changement de comportement produit.

---

## 1. Périmètre et frontière avec la cible iOS

Le code d'entraînement **ne vit pas dans la cible iOS** (§29A). Ce dossier `ml/` est hors de la cible Xcode : il n'est
référencé par aucun groupe synchronisé du projet (`App/` et `Tests/` seulement), donc rien ici n'est compilé ni
embarqué dans l'application.

Seul le **produit final** de ce pipeline traverse la frontière : un `.mlpackage` exporté, versionné, accompagné de sa
model card, ajouté explicitement à la cible iOS.

## 2. Arborescence attendue (§29A)

```text
ml/
├── README.md            ← ce fichier (le seul présent aujourd'hui)
├── pyproject.toml       ← dépendances et outillage Python (absent)
├── configs/             ← configurations d'expériences versionnées (absent)
├── datasets/            ← manifestes de provenance/licence, PAS d'audio (absent)
├── annotations/         ← annotations en temps absolus + version de schéma (absent)
├── training/            ← boucles d'entraînement et distillation (absent)
├── evaluation/          ← métriques, corpus de référence, comparaison A/B (absent)
├── export_coreml/       ← conversion `.mlpackage` + vérifications (absent)
└── model_cards/         ← une carte par modèle exporté (voir model_cards/README.md)
```

Les dossiers marqués « absent » **ne sont pas créés vides** : un dossier vide donnerait l'illusion d'un pipeline
commencé. Ils seront créés au moment où ils contiendront réellement quelque chose.

## 3. Modèles recommandés (§29A)

### 3.1 `BeatDownbeatModel`

- **Entrée** : log-spectrogramme ou Mel-spectrogramme.
- **Sortie** : probabilités **beat** et **downbeat** par frame (éventuellement position métrique, §19.2).
- **Architecture** : mobile — TCN ou CRNN compacte, ou modèle distillé.
- **Post-traitement HORS modèle** (§19.2 : « afin de pouvoir comparer plusieurs décodeurs ») : peak picking,
  estimation de phase, programmation dynamique, conversion frames → temps absolu.
- **Contrat Swift déjà en place** : `BeatActivationModel` / `ModelInputFeatures` / `BeatActivations`.
  C'est le seul des trois modèles dont le protocole existe côté iOS aujourd'hui.

### 3.2 `MusicEmbeddingModel`

- **Entrée** : fenêtres audio ou spectrales.
- **Sortie** : embeddings compacts.
- **Usage** : détection de répétitions, similarité, frontières structurelles (§22).
- Aucun protocole Swift n'existe encore : il sera défini avec le modèle, pas avant.

### 3.3 `FunctionalStateModel`

- **Entrée** : embeddings + caractéristiques rythmiques et énergétiques.
- **Sortie** : probabilités des fonctions dramaturgiques (§12.3).
- **Décodage temporel** dans l'application ou dans un post-processeur séparé — jamais dans le modèle.
- Aucun protocole Swift n'existe encore.

## 4. Données et annotations (§29A) — règles non négociables

- **Ne JAMAIS inclure un fichier audio dans un dataset d'entraînement sans droit adapté.** Aucun scraping, aucun
  fichier « trouvé », aucune bibliothèque personnelle sans licence explicite. En cas de doute : le fichier n'entre pas.
- **Manifeste de provenance et de licence obligatoire** dans `datasets/` : pour chaque morceau, source, titulaire des
  droits, licence exacte, date d'obtention, usage autorisé (entraînement ? redistribution ? évaluation seule ?).
  Le manifeste est versionné ; l'audio, lui, n'est pas commité dans le dépôt.
- **Séparation entraînement / validation / test par morceau et par artiste** lorsque c'est pertinent : deux extraits
  du même titre — ou deux titres du même artiste au style très marqué — ne doivent pas se retrouver de part et
  d'autre de la coupure, sous peine de mesurer une fuite au lieu d'une généralisation.
- **Annotations en temps absolus, avec version de schéma.** Pas d'index de frame dépendant d'un hop : un changement
  de configuration d'analyse (§16.3) ne doit pas invalider silencieusement les annotations.
- **Conserver les désaccords entre annotateurs** au lieu de fabriquer une vérité artificielle (§29A). Un beat
  ambigu, un downbeat contesté, une frontière floue : l'information de désaccord est un signal, notamment pour la
  calibration des confiances (§86), et ne doit pas être écrasée par un vote majoritaire silencieux.
- **Ancres de montage humaines** : annoter priorité, force et fenêtre tolérée (§29A), cohérentes avec le modèle
  d'ancres du moteur (§25).

## 5. Augmentations autorisées (§29A)

- changement **modéré** de tempo ;
- transposition ;
- égalisation ;
- compression dynamique ;
- ajout de bruit faible ;
- masquage fréquentiel/temporel.

**Règle d'or** : ne pas appliquer une augmentation qui invalide les timestamps sans transformer les annotations en
conséquence. Un étirement temporel non répercuté sur les annotations fabrique une vérité fausse — c'est pire que
l'absence d'augmentation.

## 6. Procédure d'export (§29A)

1. **Entraîner et évaluer** le modèle de référence (métriques et corpus décrits dans `evaluation/`).
2. **Distiller** si nécessaire pour tenir la contrainte mobile.
3. **Convertir en `.mlpackage`**.
4. **Vérifier les opérations Core ML supportées** — une opération non supportée bascule silencieusement sur CPU ou
   fait échouer la conversion ; le constater à l'export, pas sur l'appareil de l'utilisateur.
5. **Comparer Float32, Float16 et quantification** : ce n'est pas un choix par défaut, c'est une mesure.
6. **Mesurer précision, taille, latence, mémoire et énergie** sur appareil réel, pas seulement en simulateur.
7. **Générer une model card** (voir `model_cards/README.md`).
8. **Embarquer une version explicitement identifiée** : la version du modèle est tracée avec `analysisVersion` et
   `scoreVersion` (§61) ; côté iOS, `CoreMLModelRegistry.beatActivationModelVersion()` doit alors renvoyer cette
   version au lieu de `nil`.
9. **Conserver le fallback déterministe** (§29A, §86) : un modèle absent, incompatible avec l'appareil, ou dont le
   chargement échoue ne doit JAMAIS empêcher une analyse. `HybridMusicAnalyzer` doit continuer à retomber sur
   `DeterministicMusicAnalyzer`, et `HybridAnalyzerFallbackTests` doit rester vert.

## 7. Intégration côté iOS le jour venu

Un seul point d'entrée change : **`CoreMLModelRegistry`**.

1. ajouter le `.mlpackage` (nommé `BeatDownbeatModel`, cf. `beatDownbeatDescriptor`) à la cible iOS ;
2. écrire l'adaptateur `MLModel` → `BeatActivationModel` (conversion `ModelInputFeatures` → `MLMultiArray`
   row-major, lecture des sorties par frame) et le renvoyer depuis `beatActivationModel(in:)` ;
3. renvoyer la version réelle depuis `beatActivationModelVersion(in:)` (§61) ;
4. implémenter le décodeur hybride dans `HybridMusicAnalyzer.analyze` (le `TODO` y détaille les six étapes) ;
5. exécuter la **comparaison A/B** exigée par le §86 (« amélioration mesurable sur corpus de référence ») ;
6. seulement alors, câbler `HybridMusicAnalyzer` dans `AppEnvironment` — et mettre à jour
   `IMPLEMENTATION_STATUS.md`.

Tant que les points 1 à 5 ne sont pas faits, **le Jalon 11 reste NON TERMINÉ**, et le dire est la seule réponse
acceptable (§29A).
