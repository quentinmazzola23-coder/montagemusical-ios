# `ml/model_cards/` — Cartes de modèles (spec §29A)

> ## ⛔ AUCUNE MODEL CARD N'EXISTE — ET C'EST NORMAL
>
> Une model card décrit un modèle **réel** : ses données, ses métriques, ses limites. **Aucun modèle n'a été
> entraîné, converti ou embarqué** dans ce projet, donc ce dossier ne contient aucune carte.
>
> Écrire une carte pour un modèle inexistant — ou pour un fichier Core ML vide, ou pour un ensemble de règles
> heuristiques rebaptisé « modèle » — est précisément ce qu'interdit le **§29A « Interdiction »**.
> **Le Jalon 11 (§86) est NON TERMINÉ.**

---

## Quand créer une carte

Une model card est créée à l'**étape 7 de la procédure d'export** (§29A), c'est-à-dire :

- après entraînement et évaluation (étape 1) ;
- après conversion `.mlpackage` et vérification des opérations Core ML (étapes 3–4) ;
- après les mesures de précision, taille, latence, mémoire et énergie (étapes 5–6) ;
- **avant** l'embarquement du modèle dans la cible iOS (étape 8).

Un modèle sans carte ne doit pas être embarqué. Une carte sans mesures réelles ne doit pas être écrite.

## Nommage

```text
ml/model_cards/<NomDuModèle>-<version>.md
```

Exemple attendu : `BeatDownbeatModel-1.0.0.md`. La `<version>` est **exactement** celle inscrite dans les métadonnées
du `.mlpackage` et renvoyée côté iOS par `CoreMLModelRegistry.beatActivationModelVersion()` — c'est elle qui est
conservée avec l'analyse au titre du §61 (« version du modèle Core ML »).

## Contenu minimal d'une carte

### 1. Identité
- nom du modèle, version, date, auteur/responsable ;
- tâche exacte (ex. probabilités beat/downbeat par frame, §19.2) ;
- architecture, nombre de paramètres, éventuelle distillation.

### 2. Interface
- **entrée** : représentation (log-spectrogramme ou Mel), nombre de bins, cadence de frames, fréquence
  d'échantillonnage, normalisation attendue — doit correspondre exactement à `ModelInputFeatures` ;
- **sortie** : vecteurs par frame, ordre des canaux, plage de valeurs, cadence de sortie si différente de l'entrée —
  doit correspondre exactement à `BeatActivations` ;
- ce que le modèle **ne fait pas** : le post-traitement (peak picking, phase, programmation dynamique, conversion en
  temps absolu) reste hors modèle (§19.2).

### 3. Données
- corpus utilisés, **provenance et licence de chacun** (§29A : ne jamais inclure un fichier audio sans droit adapté) ;
- volumes, genres, tempos, langues, époques — et les biais qui en découlent ;
- découpage entraînement/validation/test **par morceau et par artiste** ;
- protocole d'annotation, version du schéma, **désaccords entre annotateurs conservés** (jamais lissés) ;
- augmentations appliquées et transformation correspondante des annotations.

### 4. Évaluation
- métriques par tâche (ex. F-mesure beat/downbeat avec tolérance explicite), avec l'intervalle de confiance ;
- résultats **par sous-groupe** (genre, tempo, présence vocale) : une moyenne globale cache les échecs ;
- **comparaison A/B contre le moteur déterministe** sur le corpus de référence (§86 : « amélioration mesurable ») —
  y compris les cas où le modèle est moins bon ;
- calibration des confiances (§86) : une probabilité de 0,8 doit signifier 80 %.

### 5. Performance sur appareil
- taille du modèle embarqué ;
- latence et mémoire mesurées sur appareil réel, par famille de puces ;
- consommation énergétique ;
- comparaison Float32 / Float16 / quantifié (§29A étape 5).

### 6. Limites et fallback
- cas connus d'échec (rubato, musique non métrique, très basse énergie, §63, §72) ;
- **comportement de repli** : modèle absent, incompatible ou échec de chargement → `CoreMLModelRegistry` renvoie
  `nil` et `HybridMusicAnalyzer` délègue au moteur déterministe (§29A étape 9, §86 « fallback déterministe toujours
  disponible ») ;
- ce que le modèle ne doit **pas** servir à décider (§0.7 : jamais de contenu inventé — pas de drop fabriqué,
  pas d'ancre fantôme).

### 7. Traçabilité
- commit du code d'entraînement, config d'expérience, seed ;
- empreinte du `.mlpackage` embarqué ;
- champs §61 associés : `analysisVersion`, `scoreVersion`, version du modèle, empreinte audio, configuration utilisée.
