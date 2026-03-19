// ViewModels/ScanViewModel.swift
// Core ViewModel managing scan and recovery state

import Foundation
import Combine
import Photos

// MARK: - App State
enum AppState {
    case home
    case scanning
    case results
    case recovering
    case complete
}

// MARK: - Permission Status
struct PermissionStatus {
    var photos: PHAuthorizationStatus

    var allGranted: Bool {
        photos == .authorized
    }

    var photosGranted: Bool {
        photos == .authorized || photos == .limited
    }
}

// MARK: - ScanViewModel
class ScanViewModel: NSObject, ObservableObject, FileScannerDelegate {

    // MARK: - Published State
    @Published var appState: AppState = .home
    @Published var scanProgress: ScanProgress = ScanProgress(currentStep: "", percentage: 0, filesFound: 0, isComplete: false)
    @Published var scanResult: ScanResult?
    @Published var selectedFiles: Set<UUID> = []
    @Published var filterType: FileType? = nil
    @Published var sortOrder: SortOrder = .date
    @Published var recoveryProgress: RecoveryProgress?
    @Published var recoveryResult: RecoveryOperationResult?
    @Published var errorMessage: String?
    @Published var permissionStatus: PermissionStatus
    @Published var selectedDepth: ScanDepth = .deep
    @Published var isShowingPermissionAlert = false

    // MARK: - Services
    private let scanner = FileScanner()
    private let recoveryService = FileRecoveryService()

    // MARK: - Sort Order
    enum SortOrder: String, CaseIterable {
        case date = "Date Deleted"
        case size = "File Size"
        case name = "Name"
        case type = "Type"
        case chance = "Recovery Chance"
    }

    // MARK: - Computed Properties

    var filteredFiles: [RecoverableFile] {
        var files = scanResult?.scannedFiles ?? []

        if let filterType = filterType {
            files = files.filter { $0.fileType == filterType }
        }

        switch sortOrder {
        case .date:
            files.sort { ($0.deletedDate ?? .distantPast) > ($1.deletedDate ?? .distantPast) }
        case .size:
            files.sort { $0.size > $1.size }
        case .name:
            files.sort { $0.name < $1.name }
        case .type:
            files.sort { $0.fileType.rawValue < $1.fileType.rawValue }
        case .chance:
            files.sort { $0.recoveryChance > $1.recoveryChance }
        }

        return files
    }

    var selectedCount: Int { selectedFiles.count }

    var selectedFilesArray: [RecoverableFile] {
        scanResult?.scannedFiles.filter { selectedFiles.contains($0.id) } ?? []
    }

    var selectedTotalSize: Int64 {
        selectedFilesArray.reduce(0) { $0 + $1.size }
    }

    var typeBreakdown: [(FileType, Int)] {
        guard let result = scanResult else { return [] }
        return FileType.allCases.compactMap { type in
            let count = result.scannedFiles.filter { $0.fileType == type }.count
            return count > 0 ? (type, count) : nil
        }.sorted { $0.1 > $1.1 }
    }

    // MARK: - Init

    override init() {
        permissionStatus = PermissionStatus(
            photos: PHPhotoLibrary.authorizationStatus(for: .readWrite)
        )
        super.init()
        scanner.delegate = self
    }

    // MARK: - Permissions

    func requestPermissions() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            DispatchQueue.main.async {
                self?.permissionStatus.photos = status
            }
        }
    }
    // MARK: - Scan Control

    func startScan() {
        guard permissionStatus.photosGranted else {
            isShowingPermissionAlert = true
            return
        }

        appState = .scanning
        selectedFiles = []
        scanResult = nil
        errorMessage = nil

        scanner.startScan(depth: selectedDepth)
    }

    func cancelScan() {
        scanner.cancel()
        appState = .home
    }

    // MARK: - Selection

    func toggleSelection(_ file: RecoverableFile) {
        if selectedFiles.contains(file.id) {
            selectedFiles.remove(file.id)
        } else {
            selectedFiles.insert(file.id)
        }
    }

    func selectAll() {
        selectedFiles = Set(filteredFiles.map { $0.id })
    }

    func deselectAll() {
        selectedFiles = []
    }

    func selectByType(_ type: FileType) {
        let typeFiles = scanResult?.scannedFiles.filter { $0.fileType == type } ?? []
        typeFiles.forEach { selectedFiles.insert($0.id) }
    }

    func selectHighChance() {
        let highChance = scanResult?.scannedFiles.filter { $0.recoveryChance >= 0.8 } ?? []
        highChance.forEach { selectedFiles.insert($0.id) }
    }

    // MARK: - Recovery

    func recoverSelected(to destination: FileRecoveryService.RecoveryDestination) {
        guard !selectedFiles.isEmpty else { return }

        let filesToRecover = selectedFilesArray

        guard recoveryService.hasEnoughSpace(for: filesToRecover) else {
            errorMessage = "Not enough storage space to recover selected files."
            return
        }

        appState = .recovering

        recoveryService.recoverFiles(
            filesToRecover,
            to: destination,
            progress: { [weak self] progress in
                DispatchQueue.main.async {
                    self?.recoveryProgress = progress
                }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let operationResult):
                        self?.recoveryResult = operationResult
                        self?.appState = .complete
                    case .failure(let error):
                        self?.errorMessage = error.localizedDescription
                        self?.appState = .results
                    }
                }
            }
        )
    }

    func resetToHome() {
        appState = .home
        scanResult = nil
        selectedFiles = []
        recoveryResult = nil
        recoveryProgress = nil
        errorMessage = nil
    }

    func rescan() {
        appState = .home
        selectedFiles = []
        recoveryResult = nil
        startScan()
    }

    // MARK: - FileScannerDelegate

    func scanner(_ scanner: FileScanner, didUpdateProgress progress: ScanProgress) {
        self.scanProgress = progress
    }

    func scanner(_ scanner: FileScanner, didFinishWith result: ScanResult) {
        self.scanResult = result
        self.appState = .results
    }

    func scanner(_ scanner: FileScanner, didFailWith error: Error) {
        self.errorMessage = error.localizedDescription
        self.appState = .home
    }
}

// MARK: - Recovery Store (Session History)
class RecoveryStore: ObservableObject {
    @Published var sessions: [RecoverySession] = []

    func addSession(_ session: RecoverySession) {
        sessions.insert(session, at: 0)
        saveToUserDefaults()
    }

    private func saveToUserDefaults() {
        // Persist sessions to UserDefaults
        if let encoded = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(encoded, forKey: "recovery_sessions")
        }
    }

    func loadSessions() {
        if let data = UserDefaults.standard.data(forKey: "recovery_sessions"),
           let decoded = try? JSONDecoder().decode([RecoverySession].self, from: data) {
            sessions = decoded
        }
    }
}
