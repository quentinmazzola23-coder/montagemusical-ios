import Foundation
import Observation
import SwiftData

/// Conteneur de services de l'application (spec §6).
///
/// Jalon 3 : expose l'import audio (`AudioImporter`), l'accès aux fichiers
/// de projet (`ProjectFileStore`) et l'extraction de forme d'onde
/// (`WaveformExtractor`) en plus de la persistance (Jalon 2) et du logger.
/// Les services des jalons suivants s'y branchent :
/// - Jalon 4+ : analyse musicale (`MusicAnalyzing`), génération de scores
///   (`EditScoreGenerating`), photothèque (`MediaLibraryBrowsing`) ;
/// - Jalon 9 : prévisualisation (`PreviewBuilder` + cache §48) ;
/// - Jalon 10 : export (`ProjectExporter`, `ExportActor`, `PhotoLibrarySaver`).
///
/// `@Observable` pour permettre l'injection via `.environment(_:)` et la
/// lecture via `@Environment(AppEnvironment.self)` dans les vues.
@MainActor
@Observable
final class AppEnvironment {
    /// Logger de la catégorie « app » pour le cycle de vie général.
    let logger: AppLogger

    /// Conteneur SwiftData partagé (schéma : `ProjectRecord`,
    /// `ProjectSlotRecord`, `ClipAssignmentRecord`).
    let modelContainer: ModelContainer

    /// Accès acteur à la persistance des projets (création, résumés,
    /// renommage, duplication, suppression — spec §31, §59, §60).
    let projectStore: ProjectStore

    /// Fichiers lourds des projets hors SwiftData (arbre §11) — même racine
    /// par défaut (`Application Support/Projects/`) que celle utilisée en
    /// interne par `ProjectStore`.
    let fileStore: ProjectFileStore

    /// Import audio (Jalon 3, §62, §78) : validation réelle AVFoundation
    /// puis copie dans `audio/original.<extension>` (§11).
    let audioImporter: AudioImporter

    /// Extraction de la forme d'onde (§16.2, §68) : pics normalisés 0...1,
    /// lecture par blocs pour limiter la mémoire.
    let waveformExtractor: WaveformExtractor

    /// Cache d'analyse et checkpoints de phase dans `analysis/` (§11, §69).
    let analysisCache: AnalysisCache

    /// Moteur musical niveau A (Jalon 4, §15, §79) — protocole
    /// `MusicAnalyzing` §7 ; le moteur avancé Core ML (Jalon 11) se branche
    /// derrière le même protocole. Existentiel `Sendable` : le moteur est
    /// consommé depuis `AudioAnalysisActor`, hors `@MainActor`.
    let musicAnalyzer: any MusicAnalyzing & Sendable

    /// Acteur d'analyse (§8) : une analyse lourde à la fois par projet,
    /// progression observable, annulation avec checkpoint conservé (§8.1).
    let audioAnalysisActor: AudioAnalysisActor

    /// Lecture des partitions générées (`analysis/scores-v1.json`, §11) et
    /// de leur validité §61 — écran du choix du rythme (Jalon 6, §34).
    let scoreLibrary: ScoreLibrary

    /// Accès PhotoKit (Jalon 8, §8 « MediaLibraryActor », §40–§46) :
    /// autorisations, albums, assets vidéo, résolution AVAsset réelle avec
    /// progression de téléchargement iCloud.
    let mediaLibrary: MediaLibraryActor

    /// Miniatures de la grille vidéo (Jalon 8, §42) : `PHCachingImageManager`
    /// avec préchargement autour de la zone visible — jamais de décodage 4K.
    let thumbnailProvider: ThumbnailProvider

    /// Construction des compositions de prévisualisation (Jalon 9, §48) :
    /// musique de zéro à la fin de la portée, plages vidéo successives sans
    /// l'audio des rushs, transformations géométriques appliquées (§49, §50).
    /// Type concret `@MainActor` — il porte la signature §7
    /// `makePreview(for:scope:)` sans déclarer la conformance (le résultat
    /// `AVPlayerItem` n'est pas `Sendable` ; voir PreviewBuilder.swift).
    let previewBuilder: PreviewBuilder

    /// Cache des COMPOSITIONS de prévisualisation (Jalon 9, §48 : « mettre en
    /// cache la composition tant que les associations ne changent pas »).
    /// Le cache conserve un couple immuable composition/videoComposition —
    /// jamais un `AVPlayerItem`, qui ne peut être rattaché qu'à un seul
    /// lecteur : l'item est reconstruit à chaque présentation. Invalidé par
    /// `invalidateAll(projectID:)` dès qu'une association ou la géométrie
    /// change — ce qui purge du même coup les sources d'aperçu matérialisées
    /// dans `previews/` (§11).
    let previewCache: PreviewCache

    /// Construction et encodage du montage exporté (Jalon 10, timeline
    /// CONCATÉNÉE des zones remplies — écart produit du 13 août 2026 qui
    /// remplace le préfixe §51 —, §52 profil maître, §53 exactitude
    /// temporelle, §54 composition, §55 encodage unique, §57 estimation de
    /// taille). Type concret `@MainActor`
    /// — il porte la signature §7 `ProjectExporting` sans nécessairement
    /// déclarer la conformance (même choix documenté qu'au Jalon 9 pour
    /// `PreviewBuilder`).
    let projectExporter: ProjectExporter

    /// Acteur d'export (§8, §58) : **un seul export actif par projet**,
    /// progression interrogeable, annulation, dernier résultat conservé
    /// (§60 : « dernier export réussi » restauré à la réouverture).
    let exportActor: ExportActor

    /// Enregistrement du montage dans Photos (§40 : l'autorisation
    /// d'ÉCRITURE est demandée au PREMIER enregistrement, §55 :
    /// « enregistrement dans Photos seulement après succès complet »,
    /// §66 : refus → le fichier est conservé et proposé au partage).
    let photoLibrarySaver: PhotoLibrarySaver

    /// Initialiseur de production : ouvre le conteneur persistant partagé
    /// (Application Support).
    convenience init() {
        let container: ModelContainer
        do {
            container = try ModelContainerFactory.makeShared()
        } catch {
            // Échec d'ouverture de la base au démarrage : sans persistance,
            // aucune fonctionnalité n'est possible (tout est autosauvegardé,
            // spec §3.13, §59, §60). Un crash immédiat et explicite au
            // lancement est préférable à une application qui perdrait
            // silencieusement les projets de l'utilisateur.
            fatalError("Impossible d'ouvrir le conteneur SwiftData partagé : \(error)")
        }
        self.init(modelContainer: container)
    }

    /// Initialiseur d'injection — previews SwiftUI et tests
    /// (utiliser `ModelContainerFactory.makeInMemory()`).
    ///
    /// ⚠️ `fileStore` est un PARAMÈTRE, et c'est un correctif de sûreté, pas
    /// une commodité de test. Avant ce changement, cet initialiseur
    /// construisait inconditionnellement `ProjectFileStore()` — la racine de
    /// PRODUCTION — quel que soit le conteneur passé : un
    /// `AppEnvironment(modelContainer: .makeInMemory())` suivi de
    /// `performStartupMaintenance()` (ce que fait `MontageMusicalApp` au
    /// démarrage) associait une base VIDE aux dossiers §11 RÉELS et effaçait
    /// `audio/`, `analysis/` et `exports/` de tous les vrais projets, dont les
    /// enregistrements SwiftData survivaient — perte de données silencieuse
    /// (§59, §69A). Une preview enrichie ou un test d'intégration suffisait à
    /// la déclencher.
    ///
    /// Deux verrous INDÉPENDANTS répondent à ce défaut, volontairement
    /// redondants : ce paramètre (un conteneur en mémoire peut désormais être
    /// associé à une racine temporaire) et la garde de
    /// `ProjectStore.performStartupMaintenance` (ne jamais purger quand la
    /// base est vide alors que des dossiers existent). Le second protège même
    /// un appelant qui oublierait le premier.
    ///
    /// `musicAnalyzer` et `scoreGenerator` sont injectables derrière leurs
    /// protocoles §7 : un test peut substituer un moteur instrumenté sans
    /// toucher au reste de l'environnement. Les valeurs par défaut sont
    /// EXACTEMENT la composition de production (moteur déterministe niveau A
    /// branché sur le cache §69 de la racine fournie, générateur
    /// déterministe), donc aucun appelant existant ne change de comportement.
    init(
        modelContainer: ModelContainer,
        fileStore: ProjectFileStore = ProjectFileStore(),
        musicAnalyzer: (any MusicAnalyzing & Sendable)? = nil,
        scoreGenerator: any EditScoreGenerating & Sendable = DeterministicEditScoreGenerator()
    ) {
        self.logger = AppLogger(category: .app)
        self.modelContainer = modelContainer
        let projectStore = ProjectStore(modelContainer: modelContainer, fileStore: fileStore)
        self.projectStore = projectStore
        self.fileStore = fileStore
        self.audioImporter = AudioImporter(fileStore: fileStore)
        self.waveformExtractor = WaveformExtractor()
        let analysisCache = AnalysisCache(fileStore: fileStore)
        self.analysisCache = analysisCache
        // Le moteur par défaut dépend du cache ET de la racine effectivement
        // injectés : il ne peut donc pas être une valeur par défaut de
        // paramètre (elle serait évaluée avant `analysisCache`). D'où le
        // paramètre optionnel + repli explicite ici.
        let resolvedAnalyzer: any MusicAnalyzing & Sendable
        if let musicAnalyzer {
            resolvedAnalyzer = musicAnalyzer
        } else {
            resolvedAnalyzer = DeterministicMusicAnalyzer(cache: analysisCache, fileStore: fileStore)
        }
        self.musicAnalyzer = resolvedAnalyzer
        self.audioAnalysisActor = AudioAnalysisActor(
            analyzer: resolvedAnalyzer,
            scoreGenerator: scoreGenerator,
            projectStore: projectStore,
            fileStore: fileStore
        )
        self.scoreLibrary = ScoreLibrary(fileStore: fileStore)
        let mediaLibrary = MediaLibraryActor()
        self.mediaLibrary = mediaLibrary
        self.thumbnailProvider = ThumbnailProvider()
        self.previewBuilder = PreviewBuilder(fileStore: fileStore, mediaLibrary: mediaLibrary)
        // Le cache reçoit les fichiers du projet : invalider une composition,
        // c'est aussi jeter les SOURCES d'aperçu matérialisées dans
        // `previews/` (§11, §48) — sans quoi un rush recomposé (ralenti,
        // timelapse) laisserait son ré-encodage sur le disque pour toute la
        // vie du projet.
        self.previewCache = PreviewCache(fileStore: fileStore)
        let projectExporter = ProjectExporter(fileStore: fileStore, mediaLibrary: mediaLibrary)
        self.projectExporter = projectExporter
        // §8/§58 : l'acteur sérialise les exports par projet et porte les
        // transitions de statut §10 (`setExporting`) ainsi que la mémoire du
        // dernier export réussi §60 (`markExportSucceeded`) — la vue ne les
        // écrit jamais elle-même.
        self.exportActor = ExportActor(
            exporter: projectExporter,
            projectStore: projectStore,
            fileStore: fileStore
        )
        self.photoLibrarySaver = PhotoLibrarySaver()
    }

    /// Maintenance au lancement (§69A) : brouillons vides résiduels,
    /// dossiers orphelins, vidage des `temp/`. Les erreurs sont journalisées,
    /// jamais bloquantes pour le démarrage.
    func performStartupMaintenance() async {
        do {
            try await projectStore.performStartupMaintenance()
        } catch {
            logger.error("Maintenance au lancement impossible : \(error.localizedDescription)")
        }
    }
}
