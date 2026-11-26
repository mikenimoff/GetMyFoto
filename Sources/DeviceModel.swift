import AppKit
import SwiftUI
import ImageCaptureCore
import UniformTypeIdentifiers

struct MediaItem: Identifiable {
    let id: String
    let file: ICCameraFile
    let name: String
    let bytes: Int64
    let date: Date?
    let kind: String
    var symbol: String { kind == "Видео" ? "video" : kind == "Фото" ? "photo" : "doc" }
}

final class DeviceModel: NSObject, ObservableObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    @Published var devices: [ICCameraDevice] = []
    @Published var camera: ICCameraDevice?
    @Published var items: [MediaItem] = []
    @Published var selected: Set<String> = []
    @Published var ready = false
    @Published var connectionIssue = false
    @Published var busy = false
    @Published var deleting = false
    @Published var stopping = false
    @Published var status = "Подключите iPhone по USB"
    @Published var detail = "Разблокируйте экран и нажмите «Доверять» на iPhone."
    @Published var fraction: Double = 0
    @Published var folder: URL? {
        didSet {
            UserDefaults.standard.set(folder?.path, forKey: "destination")
            reloadHistory()
        }
    }
    @Published var byMonth = true
    @Published var skipImported = true
    @Published var knownImported: Set<String> = []
    @Published var report = ""
    @Published var alert: String?

    private var browser = ICDeviceBrowser()
    private var connectionStarted: Date?
    private var catalogPolledAt = Date.distantPast
    private var lastCatalogCount = -1
    private var restartingBrowser = false
    private var catalogSummaryVisible = true
    private var history = ImportHistory()
    private var historyError: String?
    private var queue: [MediaItem] = []
    private var batchID = UUID()
    private var batchRoot: URL?
    private var batchByMonth = true
    private var batchSkip = true
    private var index = 0
    private var copied = 0
    private var skipped = 0
    private var failed = 0
    private var operationProgress: Progress?
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var refreshPending = false

    override init() {
        super.init()
        if let path = UserDefaults.standard.string(forKey: "destination") { folder = URL(fileURLWithPath: path) }
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.busy {
                if Date().timeIntervalSince(self.catalogPolledAt) >= 1 {
                    self.catalogPolledAt = Date()
                    self.pollCatalog()
                }
                return
            }
            let part = self.operationProgress?.fractionCompleted ?? 0
            self.fraction = self.deleting ? part : (Double(self.index) + part) / Double(max(1, self.queue.count))
        }
    }

    func start() { connectionStarted = Date(); browser.start() }
    private static func identity(_ device: ICDevice) -> USBDeviceIdentity {
        USBDeviceIdentity(persistentID: device.persistentIDString, uuid: device.uuidString,
                          serial: device.serialNumberString, location: device.usbLocationID)
    }
    var chosen: [MediaItem] { items.filter { selected.contains($0.id) } }
    var chosenBytes: Int64 { chosen.reduce(0) { $0 + $1.bytes } }
    var supportsDeletion: Bool { camera?.capabilities.contains(ICDeviceCapability.cameraDeviceCanDeleteOneFile.rawValue) == true }
    static func displayName(_ device: ICDevice) -> String {
        guard let name = device.name, !name.isEmpty, !name.hasPrefix("LOC:") else { return "USB-устройство" }
        return name
    }
    var canDelete: Bool {
        ready && !busy && !chosen.isEmpty && supportsDeletion
    }
    func refreshImportStatus() { reloadHistory() }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        panel.message = "Куда сохранить фото и видео с iPhone?"
        panel.directoryURL = folder
        if panel.runModal() == .OK { folder = panel.url }
    }

    func revealFolder() { if let folder { NSWorkspace.shared.open(folder) } }

    func connect(_ device: ICCameraDevice) {
        guard !busy, camera !== device else { return }
        closeCurrentSession()
        ThumbnailStore.shared.resetConnection()
        camera = device
        items = []; selected = []; ready = false; connectionIssue = false; knownImported = []
        connectionStarted = Date(); lastCatalogCount = -1
        catalogSummaryVisible = true
        device.delegate = self
        status = "Подключение к \(Self.displayName(device))…"
        detail = "Разблокируйте iPhone и разрешите доступ к фото и видео."
        if device.hasOpenSession { pollCatalog() } else { device.requestOpenSession() }
    }

    func reconnect() {
        guard !busy else { return }
        if let camera, ready, camera.hasOpenSession, !camera.isAccessRestrictedAppleDevice {
            catalogReady(camera)
            return
        }
        // Reopening an obsolete ICCameraDevice cannot recover a dead driver endpoint.
        // Discard its device references and restart discovery. A healthy session
        // only needs its catalog refreshed, without tearing down a working driver.
        closeCurrentSession()
        ThumbnailStore.shared.resetConnection()
        camera = nil; devices = []; items = []; selected = []; knownImported = []
        ready = false; connectionIssue = false; connectionStarted = Date()
        status = "Повторный поиск iPhone…"
        catalogSummaryVisible = true
        detail = "Ищем новое USB-соединение. Оставьте iPhone разблокированным."
        restartingBrowser = true
        browser.stop()
        let replacement = browser
        // stop() unregisters the previous driver asynchronously. Starting another
        // browser in the same run-loop turn can have that registration removed too.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self, weak replacement] in
            guard let self, let replacement, self.browser === replacement else { return }
            self.restartingBrowser = false
            replacement.delegate = self
            replacement.start()
            // Some drivers retain an already enumerated device across stop/start.
            // Consume the current snapshot as well as future didAdd callbacks.
            for device in replacement.devices ?? [] {
                self.deviceBrowser(replacement, didAdd: device, moreComing: false)
            }
        }
    }

    private func closeCurrentSession() {
        guard let previous = camera else { return }
        // The block API does not depend on keeping the old device delegate alive
        // until the driver's asynchronous close operation has completed.
        if previous.hasOpenSession { previous.requestCloseSession(options: nil) { _ in } }
        previous.delegate = nil
    }

    private func pollCatalog() {
        guard !ready, !busy else { return }
        guard let camera else {
            if let started = connectionStarted, Date().timeIntervalSince(started) > 15 {
                connectionStarted = nil; connectionIssue = true
                status = "iPhone не найден"
                detail = "Переподключите USB-кабель и нажмите «Обновить»."
            }
            return
        }
        if camera.isAccessRestrictedAppleDevice {
            connectionIssue = true
            status = "iPhone ограничил доступ к медиатеке"
            detail = "На iPhone разрешите доступ к фото. После разрешения соединение продолжится автоматически."
            return
        }
        if camera.hasOpenSession {
            let count = camera.mediaFiles?.count ?? 0
            if count != lastCatalogCount {
                lastCatalogCount = count
                snapshot()
            }
            let percent = camera.contentCatalogPercentCompleted
            if percent == 100 { catalogReady(camera); return }
            if !items.isEmpty {
                connectionIssue = false
                status = "Чтение медиатеки · найдено \(items.count) файлов"
                detail = "\(percent)% · Файлы появятся по мере чтения списка."
                return
            }
        }
        if let started = connectionStarted, Date().timeIntervalSince(started) > 30 {
            connectionIssue = true
            status = "Не удалось получить список файлов"
            detail = "Нажмите «Обновить» для нового поиска iPhone. При необходимости переподключите кабель."
        }
    }

    private func catalogReady(_ device: ICCameraDevice) {
        guard camera === device else { return }
        snapshot(); ready = true; connectionIssue = false; connectionStarted = nil
        if catalogSummaryVisible && !busy { updateCatalogSummary() }
    }

    private func updateCatalogSummary() {
        status = items.isEmpty ? "На устройстве нет доступных файлов" : "iPhone подключён"
        detail = "Доступно файлов: \(items.count) · \(Self.size(items.reduce(0) { $0 + $1.bytes }))"
    }

    private func reloadHistory() {
        historyError = nil
        do { history = try folder.map { try ImportHistory.load(from: $0) } ?? ImportHistory() }
        catch { history = ImportHistory(); historyError = error.localizedDescription }
        if let folder { knownImported = Set(items.filter { history.alreadyImported($0.id, root: folder) }.map(\.id)) }
        else { knownImported = [] }
    }

    private func snapshot() {
        guard let camera else { return }
        let deviceID = camera.serialNumberString ?? camera.uuidString ?? camera.name ?? "USB"
        var seen = Set<ObjectIdentifier>()
        var seenKeys = Set<String>()
        var result: [MediaItem] = []
        func append(_ file: ICCameraFile) {
            guard seen.insert(ObjectIdentifier(file)).inserted else { return }
            var components = [file.name ?? file.originalFilename ?? "Untitled"]
            var parent = file.parentFolder
            while let current = parent { components.insert(current.name ?? "", at: 0); parent = current.parentFolder }
            let date = file.exifCreationDate ?? file.fileCreationDate ?? file.creationDate
            let uti = file.uti.flatMap { UTType($0) }
            let ext = ((file.name ?? "") as NSString).pathExtension.lowercased()
            let kind = uti?.conforms(to: .movie) == true || ["mov", "mp4", "m4v", "avi"].contains(ext) ? "Видео"
                : uti?.conforms(to: .image) == true || ["heic", "heif", "jpg", "jpeg", "png", "dng", "gif", "tiff"].contains(ext) ? "Фото" : "Другое"
            let key = ImportStorage.key(device: deviceID, path: components.joined(separator: "/"), size: Int64(file.fileSize), date: file.fileModificationDate ?? date)
            if seenKeys.insert(key).inserted {
                result.append(MediaItem(id: key, file: file, name: file.name ?? file.originalFilename ?? "Untitled", bytes: Int64(file.fileSize), date: date, kind: kind))
            }
            for sidecar in file.sidecarFiles ?? [] { if let sidecar = sidecar as? ICCameraFile { append(sidecar) } }
        }
        func walk(_ item: ICCameraItem) {
            if let file = item as? ICCameraFile { append(file) }
            else if let folder = item as? ICCameraFolder { for child in folder.contents ?? [] { walk(child) } }
        }
        for item in camera.mediaFiles ?? [] { walk(item) }
        if result.isEmpty { for item in camera.contents ?? [] { walk(item) } }
        items = result.sorted { ($0.date ?? .distantPast) == ($1.date ?? .distantPast) ? $0.name < $1.name : ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        selected.formIntersection(Set(items.map(\.id)))
        reloadHistory()
        if ready && catalogSummaryVisible && !busy { updateCatalogSummary() }
    }

    private func scheduleSnapshot() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            self.snapshot()
        }
    }

    func importSelected() {
        guard ready, !busy, !chosen.isEmpty, let folder else { return }
        reloadHistory()
        if let historyError { alert = "Не удалось прочитать историю импорта: \(historyError)\nВыберите другую папку или восстановите .getmyfoto-history.json."; return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Check write access before starting any device transfer.
            try history.save(to: folder)
            let required = chosen.filter { !skipImported || !knownImported.contains($0.id) }.reduce(Int64(0)) { $0 + $1.bytes }
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: folder.path)
            if let free = attrs[.systemFreeSize] as? NSNumber, free.int64Value < required + 50_000_000 {
                alert = "Недостаточно свободного места. Для выбранных файлов нужно около \(Self.size(required))."; return
            }
        } catch { alert = "Не удалось открыть папку для записи: \(error.localizedDescription)"; return }
        queue = chosen; index = 0; copied = 0; skipped = 0; failed = 0
        batchRoot = folder; batchByMonth = byMonth; batchSkip = skipImported
        batchID = UUID(); busy = true; deleting = false; stopping = false; fraction = 0
        catalogSummaryVisible = false
        report = "GetMyFoto \(AppVersion.display) — импорт\n\(Date())\nПапка: \(folder.path)\n\n"
        beginActivity()
        nextFile()
    }

    private func nextFile() {
        guard busy, !deleting, let root = batchRoot else { return }
        if stopping || index >= queue.count { finishImport(); return }
        let item = queue[index]
        if batchSkip && history.alreadyImported(item.id, root: root) {
            skipped += 1; report += "Пропущен (уже скопирован): \(item.name)\n"
            selected.remove(item.id); index += 1
            DispatchQueue.main.async { self.nextFile() }
            return
        }
        let token = batchID
        let staging = root.appendingPathComponent(".getmyfoto-transfer-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true) }
        catch { alert = error.localizedDescription; stopping = true; finishImport(); return }
        status = "Копирование \(index + 1) из \(queue.count)"
        detail = "\(item.name) · \(Self.size(item.bytes))"
        operationProgress = item.file.requestDownload(options: [
            .downloadsDirectoryURL: staging,
            .saveAsFilename: ImportStorage.safeName(item.name),
            .overwrite: false,
            .deleteAfterSuccessfulDownload: false,
            .sidecarFiles: false
        ]) { [weak self] filename, error in
            DispatchQueue.main.async {
                defer { try? FileManager.default.removeItem(at: staging) }
                guard let self, self.batchID == token, self.busy else { return }
                self.operationProgress = nil
                do {
                    if let error { throw error }
                    guard let filename,
                          let source = ImportStorage.stagedFile(root: staging, returnedName: filename) else {
                        throw self.failure("iPhone не вернул сохранённый файл.")
                    }
                    let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
                    let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                    guard attrs[.type] as? FileAttributeType == .typeRegular, bytes > 0 else { throw self.failure("Получен пустой файл.") }
                    // Sizes can change if iOS converts HEIC/HEVC on transfer. Completion without
                    // error is the transport's success signal; store the actual received size.
                    let targetFolder = self.batchByMonth ? root.appendingPathComponent(ImportStorage.month(item.date), isDirectory: true) : root
                    try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
                    let target = ImportStorage.uniqueURL(folder: targetFolder, name: item.name)
                    try FileManager.default.moveItem(at: source, to: target)
                    if let date = item.date { try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: target.path) }
                    self.copied += 1
                    self.report += "Скопирован: \(target.path) (\(bytes) байт)\n"
                    let relative = String(target.path.dropFirst(root.path.count + 1))
                    self.history.files[item.id] = ImportRecord(relativePath: relative, bytes: bytes, importedAt: Date())
                    do { try self.history.save(to: root) }
                    catch {
                        self.report += "Ошибка записи истории: \(error.localizedDescription)\n"
                        self.alert = "Файл сохранён, но история импорта не записана: \(error.localizedDescription)"
                        self.stopping = true
                    }
                    self.selected.remove(item.id)
                } catch {
                    self.failed += 1
                    self.report += "ОШИБКА: \(item.name) — \(error.localizedDescription)\n"
                }
                self.index += 1
                self.nextFile()
            }
        }
    }

    private func finishImport() {
        let stopped = stopping
        busy = false; operationProgress = nil; fraction = Double(index) / Double(max(1, queue.count))
        endActivity()
        status = stopped ? "Копирование остановлено" : failed == 0 ? "Готово" : "Завершено с ошибками"
        detail = "Скопировано: \(copied) · Пропущено: \(skipped) · Ошибок: \(failed)"
        report += "\n\(status). \(detail)\n"
        reloadHistory()
    }

    func stop() {
        guard busy else { return }
        if deleting { camera?.cancelDelete(); detail = "Остановка удаления…" }
        else { stopping = true; detail = "Текущий файл будет докопирован, затем перенос остановится." }
    }

    // Called only by the confirmation sheet with the frozen, reviewed selection.
    func deleteConfirmed(_ reviewed: [MediaItem], deviceIdentity: ObjectIdentifier) {
        guard canDelete, let camera, !reviewed.isEmpty else { return }
        let available = Dictionary(uniqueKeysWithValues: items.map { ($0.id, ObjectIdentifier($0.file)) })
        guard ObjectIdentifier(camera) == deviceIdentity,
              reviewed.allSatisfy({ available[$0.id] == ObjectIdentifier($0.file) }) else {
            alert = "Список файлов изменился. Выберите файлы заново."; return
        }
        busy = true; deleting = true; stopping = false; fraction = 0; batchID = UUID()
        catalogSummaryVisible = false
        let token = batchID
        status = "Удаление с iPhone…"
        detail = "Выбрано файлов: \(reviewed.count). Не отключайте кабель."
        report = "GetMyFoto \(AppVersion.display) — удаление\n\(Date())\n\n"
        beginActivity()
        operationProgress = camera.requestDeleteFiles(reviewed.map(\.file), deleteFailed: { [weak self] errors in
            DispatchQueue.main.async {
                guard let self, self.batchID == token else { return }
                for (reason, item) in errors { self.report += "ОШИБКА: \(item.name ?? "Файл") — \(reason.rawValue)\n" }
            }
        }, completion: { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.batchID == token, self.busy else { return }
                let successes = result[.successful] ?? []
                let successObjects = Set(successes.map { ObjectIdentifier($0) })
                for item in reviewed {
                    self.report += "\(successObjects.contains(ObjectIdentifier(item.file)) ? "Удалён" : "Не удалён"): \(item.name)\n"
                }
                if let error { self.report += "\n\(error.localizedDescription)\n" }
                self.items.removeAll { successObjects.contains(ObjectIdentifier($0.file)) }
                self.selected.subtract(Set(reviewed.filter { successObjects.contains(ObjectIdentifier($0.file)) }.map(\.id)))
                self.busy = false; self.deleting = false; self.operationProgress = nil
                self.endActivity()
                self.status = error == nil ? "Удаление завершено" : "Удаление завершено с ошибками"
                self.detail = "Удалено: \(successes.count) из \(reviewed.count). Подробности — в отчёте."
                self.fraction = 1
                self.scheduleSnapshot()
            }
        })
    }

    private func beginActivity() { activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Перенос файлов iPhone") }
    private func endActivity() { if let activity { ProcessInfo.processInfo.endActivity(activity) }; activity = nil }
    private func failure(_ text: String) -> NSError { NSError(domain: "GetMyFoto", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    static func size(_ bytes: Int64) -> String { bytes == 0 ? "0 Б" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard browser === self.browser, !restartingBrowser, let device = device as? ICCameraDevice,
              device.transportType == ICDeviceTransport.transportTypeUSB.rawValue else { return }
        let shouldFollow = camera.map { Self.identity($0).matches(Self.identity(device)) } ?? true
        if let index = devices.firstIndex(where: { $0 === device || Self.identity($0).matches(Self.identity(device)) }) {
            devices[index] = device
        } else { devices.append(device) }
        if shouldFollow && camera !== device {
            if busy {
                batchID = UUID(); busy = false; deleting = false; operationProgress = nil; endActivity()
                report += "\nДрайвер заменил USB-соединение. Незавершённая операция остановлена.\n"
            }
            connect(device)
        }
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard browser === self.browser else { return }
        didRemove(device)
    }
    func didRemove(_ device: ICDevice) {
        devices.removeAll { $0 === device }
        guard camera === device else { return }
        ThumbnailStore.shared.resetConnection()
        batchID = UUID(); busy = false; deleting = false; operationProgress = nil; endActivity()
        camera = nil; items = []; selected = []; ready = false; knownImported = []
        connectionIssue = false; connectionStarted = nil
        status = "iPhone отключён"
        detail = "Подключите кабель снова. Завершённые копии сохранены."
        report += "\nУстройство отключено. Незавершённый файл не засчитан.\n"
    }
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        guard camera === device else { return }
        if let error { connectionIssue = true; status = "Не удалось подключиться"; detail = error.localizedDescription }
        else if camera?.isAccessRestrictedAppleDevice == true {
            status = "Разблокируйте iPhone"
            detail = "Подтвердите доверие к этому Mac и доступ к фото на экране телефона."
        } else {
            status = "Чтение списка файлов…"
            detail = "Большая медиатека может загружаться несколько минут. iPhone должен быть разблокирован."
            pollCatalog()
        }
    }
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        guard camera === device else { return }
        ready = false
        connectionIssue = true
        if busy {
            batchID = UUID(); busy = false; deleting = false; operationProgress = nil; endActivity()
            report += "\nСессия с устройством закрыта: \(error?.localizedDescription ?? "нет соединения")\n"
        }
        status = "Соединение закрыто"
        detail = error?.localizedDescription ?? "Нажмите «Обновить» для повторного подключения."
    }
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        catalogReady(device)
    }
    func deviceDidBecomeReady(_ device: ICDevice) { if camera === device { pollCatalog() } }
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) { if self.camera === camera { scheduleSnapshot() } }
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) { if self.camera === camera { scheduleSnapshot() } }
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) { if self.camera === camera { scheduleSnapshot() } }
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) { objectWillChange.send() }
    func deviceDidChangeName(_ device: ICDevice) { objectWillChange.send() }
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        guard camera === device else { return }
        connectionIssue = false; connectionStarted = Date()
        status = "Чтение медиатеки…"; detail = "Доступ разрешён. Ожидайте список файлов."
        if !device.hasOpenSession { device.requestOpenSession() } else { pollCatalog() }
    }
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) { if camera === device { ready = false; connectionIssue = true; status = "Разблокируйте iPhone"; detail = "Разрешите доступ к фото и видео на экране телефона." } }
}
