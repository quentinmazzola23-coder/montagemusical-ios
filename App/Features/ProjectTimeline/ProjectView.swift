import AVFoundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Écran projet — Jalon 3 (import audio). Trois états selon le
/// `ProjectRecord` :
///
/// 1. **Sans musique** (`audioRelativePath` nil, statut `draft`) : écran §32
///    conservé ; le bouton central « + Importer une musique » présente
///    désormais un `fileImporter` restreint aux formats §62
///    (M4A/AAC, MP3, WAV, AIFF).
/// 2. **Import en cours** (statut `importingAudio`) : `ProgressView` +
///    « Import de la musique… », dock réduit au seul bouton Projets.
/// 3. **Musique présente** (`audioRelativePath` non nil) : forme d'onde
///    (`WaveformView`), durée (`MediaTime.displayString`), lecture par
///    toucher sur la waveform et bouton Lecture/Pause au dock (ligne §36 la
///    plus proche : Retour | Lecture/Pause | —). Jalon 4 : au statut
///    `analyzing`, l'analyse réelle est pilotée par `AudioAnalysisActor`
///    (démarrage idempotent, progression §33 par polling, annulation avec
///    checkpoint à la disparition de la vue §8.1) ; `failed` a un état
///    sobre (bouton « Réessayer » §63). Jalon 6 : au statut
///    `awaitingPaceSelection`, l'écran du choix du rythme
///    (`PaceSelectionView`, §34) remplace cet état ; au statut
///    `assembling`, un placeholder sobre affiche le rythme choisi et le
///    nombre de plans avec l'action « Changer de rythme » (§65 : verrouillé
///    par des associations → alerte avec duplication).
///
/// Flux d'import (annexe A) : `setStatus(.importingAudio)` →
/// `importAudio(from:into:)` → `attachAudio` (qui place le statut sur
/// `analyzing`). En cas d'erreur : retour au statut `draft` + alerte
/// française avec le message `LocalizedError` (§62). Annulation du
/// `fileImporter` : rien — le brouillon reste (§62).
///
/// - Règle du pouce §30 : aucune action obligatoire en haut ; le retour
///   passe par le dock, le bouton retour système est masqué.
/// - Matériaux translucides sobres (§37), aucune animation décorative (§38),
///   libellés accessibles et cibles ≥ 44 pt (§39).
///
/// La vue reçoit uniquement un `UUID` : `ProjectRecord` n'est pas `Sendable`
/// et ne traverse jamais une frontière d'acteur.
struct ProjectView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    private let projectID: UUID

    /// Le projet est chargé par une `@Query` filtrée sur son identifiant :
    /// la vue se met à jour automatiquement (renommage, statut, audio…).
    @Query private var projects: [ProjectRecord]

    // MARK: État d'import (Jalon 3)

    @State private var isFileImporterPresented = false
    @State private var importErrorMessage: String?
    @State private var isImportErrorPresented = false

    // MARK: État musique présente (Jalon 3)

    /// Pics de la forme d'onde (`nil` tant que le calcul est en cours).
    @State private var waveformSamples: [Float]?
    /// Durée du fichier original — `MediaTime` via `AVURLAsset` (§9 :
    /// `Double`/`CMTime` uniquement à la frontière AVFoundation).
    @State private var audioDuration: MediaTime?
    /// Lecture du fichier ORIGINAL (§16.1), jamais de modification.
    @State private var playerController = AudioPlayerController()
    /// Vrai si `audio/` ne contient aucun fichier lisible (incohérence
    /// disque/base) — état sobre, jamais de crash.
    @State private var isMediaUnavailable = false

    // MARK: État analyse (Jalon 4)

    /// Dernière progression publiée par `AudioAnalysisActor` (§33 : phase
    /// courante + étapes terminées, jamais de pourcentage).
    @State private var analysisProgress: AnalysisProgress?

    // MARK: État assemblage (Jalon 6 — placeholder)

    /// Nombre de plans du rythme choisi (`ProjectStore.slotCount`), `nil`
    /// tant que la lecture est en cours.
    @State private var assemblingSlotCount: Int?
    /// Alerte §65 : changement de rythme refusé car des vidéos sont déjà
    /// associées — proposer la duplication, jamais de mutation destructive.
    @State private var isPaceLockAlertPresented = false
    /// Alerte générique d'échec du changement de rythme (jamais silencieux).
    @State private var isPaceChangeErrorPresented = false

    init(projectID: UUID) {
        self.projectID = projectID
        _projects = Query(filter: #Predicate<ProjectRecord> { record in
            record.id == projectID
        })
    }

    var body: some View {
        Group {
            if let project = projects.first {
                content(for: project)
            } else {
                notFoundFallback
            }
        }
        // Le dock fournit le retour (« Projets »/« Retour ») en zone basse
        // (§30) : le bouton retour système du haut est masqué.
        .navigationBarBackButtonHidden(true)
        // Formats initiaux §62 : M4A/AAC, MP3, WAV, AIFF. La validation
        // RÉELLE (piste décodable, DRM, fichier vide) est faite par
        // `AudioImporter` — l'extension seule ne suffit pas (§62).
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.mpeg4Audio, .mp3, .wav, .aiff]
        ) { result in
            switch result {
            case .success(let url):
                importMusic(from: url)
            case .failure(let error):
                // Vraie erreur du sélecteur (provider de fichiers en échec,
                // iCloud indisponible…) : jamais silencieux. L'annulation
                // utilisateur ne passe pas par `.failure` (§62 : annulé →
                // rien, le brouillon reste et sera balayé s'il reste vide §31).
                environment.logger.error("Sélecteur de fichier en échec : \(error.localizedDescription)")
                importErrorMessage = "Impossible d'ouvrir ce fichier. Réessayez, ou choisissez un autre fichier audio."
                isImportErrorPresented = true
            }
        }
        .alert("Import impossible", isPresented: $isImportErrorPresented) {
            Button("OK", role: .cancel) {
                importErrorMessage = nil
            }
        } message: {
            // Message `LocalizedError` français d'`AudioImportError` (§62) :
            // explique le problème et quoi faire.
            Text(importErrorMessage ?? "Une erreur inattendue est survenue. Réessayez avec un autre fichier audio.")
        }
    }

    // MARK: - Aiguillage des trois états

    @ViewBuilder
    private func content(for project: ProjectRecord) -> some View {
        let displayTitle = project.customTitle ?? project.automaticTitle
        let status = ProjectStatus(rawValue: project.statusRaw) ?? .draft
        Group {
            if project.audioRelativePath != nil {
                switch status {
                case .awaitingPaceSelection:
                    // Jalon 6 : choix du rythme (§34) — remplace l'état
                    // « musique présente » ; l'aperçu waveform/lecture
                    // reste réservé aux statuts d'analyse.
                    PaceSelectionView(projectID: projectID)
                case .assembling:
                    assemblingContent(for: project)
                default:
                    musicContent(status: status)
                }
            } else if status == .importingAudio {
                importingContent
            } else {
                emptyContent
            }
        }
        .navigationTitle(displayTitle)
        .toolbarTitleDisplayMode(.inline)
        // §65 : jamais de mutation destructive — proposer la duplication.
        .alert("Rythme verrouillé", isPresented: $isPaceLockAlertPresented) {
            Button("Dupliquer") {
                duplicateForPaceChange()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Ce rythme est verrouillé par des vidéos déjà associées. Dupliquez le projet pour changer de rythme.")
        }
        .alert("Action impossible", isPresented: $isPaceChangeErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Le changement de rythme a échoué. Réessayez.")
        }
    }

    // MARK: - État 1 : sans musique (§32)

    private var emptyContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            // Partie haute §32 : simple invite, aucune action obligatoire
            // au-dessus de ~65 % de la hauteur (§30).
            Text("Ajoutez une musique pour commencer")
                .font(.title3.weight(.medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .safeAreaInset(edge: .bottom) { emptyDock }
    }

    /// Dock §36 ligne « Projet vide » : `Projets` | `+ Musique` | —.
    private var emptyDock: some View {
        HStack(spacing: 12) {
            dockSecondaryButton(
                title: "Projets",
                accessibilityHint: "Revient à la liste des projets."
            ) {
                dismiss()
            }

            // Centre : action principale « + Importer une musique » (§32).
            Button {
                isFileImporterPresented = true
            } label: {
                Label("Importer une musique", systemImage: "plus")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 52) // ≥ 44 pt (§39)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Importer une musique")
            .accessibilityHint("Choisit un fichier audio M4A, MP3, WAV ou AIFF.")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - État 2 : import en cours (annexe A, §62)

    private var importingContent: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            ProgressView()
            Text("Import de la musique…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .safeAreaInset(edge: .bottom) { importingDock }
    }

    /// Dock réduit pendant l'import : seul le bouton Projets. La copie se
    /// poursuit en arrière-plan si l'utilisateur revient à l'accueil.
    private var importingDock: some View {
        HStack {
            dockSecondaryButton(
                title: "Projets",
                accessibilityHint: "Revient à la liste des projets. L'import continue."
            ) {
                dismiss()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - État 3 : musique présente (§16.1, §33, §36, §39)

    private func musicContent(status: ProjectStatus) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            // Forme d'onde — sobre : ni nom de fichier, ni métadonnées.
            waveformArea

            // Durée du morceau, précision d'affichage au centième (§9).
            if let audioDuration {
                Text(audioDuration.displayString)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Durée de la musique : \(audioDuration.displayString)")
            }

            // Jalon 4 : progression RÉELLE de l'analyse (§33 : phase
            // courante + étapes terminées, jamais de pourcentage), état
            // terminé sobre, ou échec avec « Réessayer » (§63).
            analysisStatusArea(status: status)

            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .safeAreaInset(edge: .bottom) { musicDock }
        .task(id: projectID) {
            await loadMedia()
        }
        // Pilotage de l'analyse (§8, annexe A) : au statut `analyzing`,
        // démarrage idempotent puis polling de la progression (300 ms).
        // Le changement de statut relance la `.task` (id) et arrête la
        // boucle ; la disparition de la vue l'annule.
        .task(id: status) {
            guard status == .analyzing else { return }
            await environment.audioAnalysisActor.startAnalysisIfNeeded(projectID: projectID)
            while !Task.isCancelled {
                if let progress = await environment.audioAnalysisActor.currentProgress(projectID: projectID) {
                    analysisProgress = progress
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        .onDisappear {
            // Retire l'observateur périodique et arrête la lecture.
            playerController.invalidate()
            // §8.1 : l'analyse est annulée à la sortie de l'écran — le
            // checkpoint du dernier jalon terminé est conservé et l'analyse
            // reprend à la prochaine ouverture du projet (§63).
            let analysisActor = environment.audioAnalysisActor
            let id = projectID
            Task { await analysisActor.cancelAnalysis(projectID: id) }
        }
    }

    // MARK: - Zone analyse (Jalon 4, §33, §63)

    /// Les cinq phases §33, dans l'ordre de déclaration de `AnalysisPhase`
    /// (ordre §33). Jalon 5 : la 5ᵉ phase « Création des rythmes » est
    /// publiée par `AudioAnalysisActor` après le succès de l'analyse —
    /// l'affichage indique désormais « Phase x sur 5 ».
    private static let analysisPhases: [AnalysisPhase] = AnalysisPhase.allCases

    @ViewBuilder
    private func analysisStatusArea(status: ProjectStatus) -> some View {
        switch status {
        case .analyzing:
            // §33 : phase courante + « Phase x sur 5 » — SANS pourcentage
            // (le spinner est indéterminé). Avant la première publication,
            // la première phase est affichée.
            let phase = analysisProgress?.phase ?? .audioPreparation
            let phaseNumber = (Self.analysisPhases.firstIndex(of: phase) ?? 0) + 1
            VStack(spacing: 6) {
                ProgressView()
                Text(phase.displayLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Phase \(phaseNumber) sur \(Self.analysisPhases.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Analyse en cours : \(phase.displayLabel), phase \(phaseNumber) sur \(Self.analysisPhases.count)")
        // `awaitingPaceSelection` n'arrive plus ici : le routage de
        // `content(for:)` affiche `PaceSelectionView` (§34, Jalon 6).
        case .failed:
            VStack(spacing: 8) {
                Text("L'analyse a échoué")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                // §63 : échec → bouton « Réessayer » (état sobre).
                Button("Réessayer") {
                    retryAnalysis()
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.bordered)
                .accessibilityHint("Relance l'analyse musicale du projet.")
            }
        default:
            EmptyView()
        }
    }

    /// Zone waveform : `ProgressView` pendant l'extraction, puis
    /// `WaveformView` interactive (toucher = lecture/pause).
    @ViewBuilder
    private var waveformArea: some View {
        if isMediaUnavailable {
            // Incohérence disque/base : état sobre, le dock reste utilisable.
            Text("Fichier audio introuvable")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(height: 96)
        } else if let waveformSamples {
            WaveformView(
                samples: waveformSamples,
                // Barre de position affichée seulement quand la lecture a
                // commencé — rendu sobre au repos.
                progress: playerController.isPlaying || playerController.progress > 0
                    ? playerController.progress
                    : nil
            )
            .frame(height: 96)
            .padding(.horizontal, 24)
            .contentShape(Rectangle())
            // Lecture par toucher sur la waveform (§35.1 par analogie :
            // lecture par toucher sur l'aperçu). Cible bien plus haute que
            // 44 pt (§39).
            .onTapGesture {
                playerController.togglePlayback()
            }
            .accessibilityElement()
            .accessibilityLabel("Forme d'onde de la musique")
            .accessibilityValue(playerController.isPlaying ? "Lecture en cours" : "En pause")
            .accessibilityHint("Touchez pour lancer ou mettre en pause la lecture.")
            .accessibilityAddTraits(.isButton)
        } else {
            // Extraction de la forme d'onde en cours (§16.2, lecture par
            // blocs) — jamais de faux pourcentage (§33).
            ProgressView()
                .frame(height: 96)
                .accessibilityLabel("Préparation de la forme d'onde")
        }
    }

    /// Dock §36 : « Projets » à gauche (comme tous les contextes
    /// écran-projet du tableau §36), Lecture/Pause au centre.
    private var musicDock: some View {
        HStack(spacing: 12) {
            dockSecondaryButton(
                title: "Projets",
                accessibilityHint: "Revient à la liste des projets."
            ) {
                dismiss()
            }

            // Centre : Lecture/Pause (§36, §37).
            Button {
                playerController.togglePlayback()
            } label: {
                Label(
                    playerController.isPlaying ? "Pause" : "Lecture",
                    systemImage: playerController.isPlaying ? "pause.fill" : "play.fill"
                )
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 52) // ≥ 44 pt (§39)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(isMediaUnavailable)
            .accessibilityLabel(playerController.isPlaying ? "Pause" : "Lecture")
            .accessibilityHint(
                playerController.isPlaying
                    ? "Met la musique en pause."
                    : "Lance la lecture de la musique."
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - État 4 : assemblage (Jalon 6 — placeholder sobre)

    /// Placeholder du statut `assembling` : la timeline d'assemblage
    /// (carrousel trois cases, mini-timeline §35) arrive au Jalon 7.
    /// En attendant : libellé français du rythme choisi + nombre de plans
    /// (`ProjectStore.slotCount`), action secondaire « Changer de rythme »
    /// au dock (§30 : zone basse, ≥ 44 pt).
    private func assemblingContent(for project: ProjectRecord) -> some View {
        let mode = project.selectedPaceRaw.flatMap(PaceMode.init(rawValue:))
        return VStack(spacing: 8) {
            Spacer(minLength: 0)
            if let mode {
                Text("Rythme \(mode.displayLabel)")
                    .font(.title3.weight(.medium))
            }
            if let assemblingSlotCount {
                Text(assemblingSlotCount == 1 ? "1 plan" : "\(assemblingSlotCount) plans")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                // Lecture du nombre de plans en cours — jamais de faux
                // chiffre (§33 par analogie).
                ProgressView()
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .safeAreaInset(edge: .bottom) { assemblingDock }
        .task(id: projectID) {
            do {
                assemblingSlotCount = try await environment.projectStore.slotCount(projectID: projectID)
            } catch {
                environment.logger.error("Nombre de plans illisible : \(error.localizedDescription)")
            }
        }
    }

    /// Dock du placeholder d'assemblage : `Projets` | `Changer de rythme`.
    /// (Le dock complet §36 « Case vide/remplie » arrive au Jalon 7.)
    private var assemblingDock: some View {
        HStack(spacing: 12) {
            dockSecondaryButton(
                title: "Projets",
                accessibilityHint: "Revient à la liste des projets."
            ) {
                dismiss()
            }

            Button {
                changePace()
            } label: {
                Text("Changer de rythme")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, minHeight: 52) // ≥ 44 pt (§39)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Changer de rythme")
            .accessibilityHint("Revient au choix du rythme. Les cases actuelles seront remplacées.")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - Actions Jalon 3

    /// Flux d'import — annexe A (`importMusic`).
    ///
    /// L'URL du `fileImporter` est security-scoped : c'est `AudioImporter`
    /// qui encadre `start/stopAccessingSecurityScopedResource` — l'URL brute
    /// est transmise telle quelle.
    ///
    /// `Task` volontairement détachée du cycle de vie de la vue : si
    /// l'utilisateur revient à l'accueil pendant la copie, l'import se
    /// termine et le projet est correctement mis à jour (§62 : jamais de
    /// fichier partiel abandonné — l'importeur nettoie en cas d'échec).
    private func importMusic(from url: URL) {
        Task {
            do {
                try await environment.projectStore.setStatus(.importingAudio, projectID: projectID)
                let imported = try await environment.audioImporter.importAudio(from: url, into: projectID)
                // `attachAudio` enregistre `audioRelativePath` et place le
                // statut sur `.analyzing` (annexe A) — la `.task(id: status)`
                // de l'état musique présente démarre alors l'analyse réelle
                // via `AudioAnalysisActor` (Jalon 4).
                try await environment.projectStore.attachAudio(imported, projectID: projectID)
            } catch {
                // §62 : erreur d'import → retour au brouillon + explication.
                environment.logger.error("Import audio échoué : \(error.localizedDescription)")
                do {
                    try await environment.projectStore.setStatus(.draft, projectID: projectID)
                } catch {
                    // Statut non rétabli (base indisponible) : la maintenance
                    // au lancement ramènera le projet en `draft` (§8) — ne
                    // jamais avaler l'échec en silence.
                    environment.logger.error("Retour au statut brouillon impossible : \(error.localizedDescription)")
                }
                importErrorMessage = error.localizedDescription
                isImportErrorPresented = true
            }
        }
    }

    // MARK: - Actions Jalon 4

    /// §63 : « échec : bouton Réessayer » — remet le statut à `analyzing`
    /// puis relance l'analyse (le checkpoint éventuel est réutilisé, §69).
    /// Le changement de statut déclenche aussi la `.task(id: status)` qui
    /// pilote le polling de progression.
    private func retryAnalysis() {
        analysisProgress = nil
        Task {
            do {
                try await environment.projectStore.setStatus(.analyzing, projectID: projectID)
            } catch {
                environment.logger.error("Relance de l'analyse impossible : \(error.localizedDescription)")
                return
            }
            await environment.audioAnalysisActor.startAnalysisIfNeeded(projectID: projectID)
        }
    }

    // MARK: - Actions Jalon 6

    /// Changement de rythme AVANT association (§65 : seule la mutation
    /// APRÈS association est interdite) : `revertToPaceSelection` efface
    /// les cases et ramène le statut à `awaitingPaceSelection` — le
    /// routage affiche alors `PaceSelectionView`. Si une association
    /// existe : alerte §65 avec « Dupliquer », aucune mutation.
    private func changePace() {
        Task {
            do {
                try await environment.projectStore.revertToPaceSelection(projectID: projectID)
                assemblingSlotCount = nil
            } catch ProjectStoreError.paceLockedByAssignments {
                isPaceLockAlertPresented = true
            } catch {
                environment.logger.error("Changement de rythme impossible : \(error.localizedDescription)")
                isPaceChangeErrorPresented = true
            }
        }
    }

    /// §65 : duplication POUR CHANGER DE RYTHME — la copie repart SANS
    /// associations, au choix du rythme (`duplicateForPaceChange` du store),
    /// sinon la copie serait verrouillée comme l'original (impasse). Après
    /// duplication, retour à la liste où la copie apparaît.
    /// Non defini par la specification — definition minimale V1.
    private func duplicateForPaceChange() {
        Task {
            do {
                _ = try await environment.projectStore.duplicateForPaceChange(projectID: projectID)
                dismiss()
            } catch {
                environment.logger.error("Duplication impossible : \(error.localizedDescription)")
                isPaceChangeErrorPresented = true
            }
        }
    }

    /// Charge le lecteur, la durée et la forme d'onde du fichier original.
    private func loadMedia() async {
        // Déjà chargé (retour d'arrière-plan, ré-apparition) : ne pas
        // recalculer la waveform, juste recharger le lecteur si nécessaire.
        guard let url = environment.fileStore.audioFileURL(projectID: projectID) else {
            isMediaUnavailable = true
            environment.logger.error("Aucun fichier dans audio/ alors que audioRelativePath est renseigné.")
            return
        }
        isMediaUnavailable = false
        playerController.load(url: url)

        // Durée : `AVURLAsset.load(.duration)` — conversion immédiate en
        // `MediaTime` (le `CMTime`/`Double` ne vit qu'à la frontière, §9).
        if audioDuration == nil {
            let asset = AVURLAsset(url: url)
            if let cmDuration = try? await asset.load(.duration),
               let mediaDuration = MediaTime(cmTime: cmDuration) {
                audioDuration = mediaDuration
            }
        }

        // Forme d'onde : 200 bins, extraction par blocs (§16.2, §68).
        if waveformSamples == nil {
            do {
                waveformSamples = try await environment.waveformExtractor.waveform(
                    for: url,
                    binCount: 200
                )
            } catch is CancellationError {
                // Vue disparue pendant l'extraction (`.task` annulée) :
                // laisser `nil` pour retenter à la prochaine apparition.
                return
            } catch {
                environment.logger.error("Extraction de la forme d'onde impossible : \(error.localizedDescription)")
                // Zone vide sobre : la lecture reste disponible.
                waveformSamples = []
            }
        }
    }

    // MARK: - Fallback projet introuvable (inchangé Jalon 2)

    /// Projet introuvable dans le contexte principal : soit la création vient
    /// d'être sauvegardée par le `ProjectStore` et n'est pas encore propagée,
    /// soit le projet a réellement été supprimé. On vérifie auprès du store
    /// avant de revenir à l'accueil — jamais de retour intempestif juste
    /// après « ouvrir immédiatement la timeline » (§31).
    private var notFoundFallback: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ProgressView()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        // Jamais de spinner sans issue : le dock « Projets » reste disponible
        // même si la propagation inter-contextes SwiftData tarde (§30).
        .safeAreaInset(edge: .bottom) { fallbackDock }
        .task {
            do {
                if try await environment.projectStore.summary(id: projectID) == nil {
                    dismiss()
                    return
                }
                // Le projet existe côté store mais la @Query du mainContext ne
                // le voit pas encore : on laisse 2 s à la propagation
                // inter-contextes, puis on re-vérifie avant de revenir.
                try? await Task.sleep(for: .seconds(2))
                if try await environment.projectStore.summary(id: projectID) == nil {
                    dismiss()
                }
            } catch {
                environment.logger.error("Chargement du projet impossible : \(error.localizedDescription)")
                dismiss()
            }
        }
    }

    /// Dock minimal du fallback : uniquement la sortie « Projets ».
    private var fallbackDock: some View {
        HStack {
            dockSecondaryButton(
                title: "Projets",
                accessibilityHint: "Revient à la liste des projets."
            ) {
                dismiss()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - Composants de dock partagés (§37, §39)

    /// Bouton secondaire de dock : capsule translucide, cible ≥ 44 pt.
    private func dockSecondaryButton(
        title: String,
        accessibilityHint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.medium))
                .padding(.horizontal, 20)
                .frame(minHeight: 52) // cible ≥ 44 pt (§39)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(accessibilityHint)
    }
}

// MARK: - Previews

#Preview("Sans musique") {
    let container = try! ModelContainerFactory.makeInMemory()
    let environment = AppEnvironment(modelContainer: container)
    let record = makePreviewRecord(statusRaw: ProjectStatus.draft.rawValue, audioRelativePath: nil)
    container.mainContext.insert(record)
    return NavigationStack {
        ProjectView(projectID: record.id)
    }
    .environment(environment)
    .modelContainer(container)
}

#Preview("Import en cours") {
    let container = try! ModelContainerFactory.makeInMemory()
    let environment = AppEnvironment(modelContainer: container)
    let record = makePreviewRecord(statusRaw: ProjectStatus.importingAudio.rawValue, audioRelativePath: nil)
    container.mainContext.insert(record)
    return NavigationStack {
        ProjectView(projectID: record.id)
    }
    .environment(environment)
    .modelContainer(container)
}

@MainActor
private func makePreviewRecord(statusRaw: String, audioRelativePath: String?) -> ProjectRecord {
    let now = Date.now
    return ProjectRecord(
        id: UUID(),
        automaticTitle: automaticProjectTitle(date: now),
        customTitle: nil,
        createdAt: now,
        updatedAt: now,
        statusRaw: statusRaw,
        selectedPaceRaw: nil,
        activeSlotIndex: 0,
        audioRelativePath: audioRelativePath,
        analysisRelativePath: nil,
        geometryData: nil,
        lastAlbumIdentifier: nil,
        analysisVersion: 1,
        scoreVersion: 1
    )
}
