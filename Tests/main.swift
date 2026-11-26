import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    guard condition() else { fputs("FAIL: \(label)\n", stderr); exit(1) }
    print("PASS: \(label)")
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("GetMyFoto-tests-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

check(ImportStorage.safeName("../IMG:1\n.HEIC") == ".._IMG_1.HEIC", "sanitize device filenames")
check(ImportStorage.safeName("..") == "Untitled", "reject parent directory name")
check(ImportStorage.containedURL(root: root, relative: "../outside") == nil, "reject path traversal")
check(ImportStorage.containedURL(root: root, relative: "/tmp/outside") == nil, "reject absolute history paths")
let file = root.appendingPathComponent("IMG_1.HEIC")
try Data([1, 2, 3]).write(to: file)
let target = ImportStorage.uniqueURL(folder: root, name: "IMG_1.HEIC")
check(target.lastPathComponent == "IMG_1 (2).HEIC", "never overwrite a filename collision")
try Data([4]).write(to: target)
check(ImportStorage.uniqueURL(folder: root, name: "IMG_1.HEIC").lastPathComponent == "IMG_1 (3).HEIC", "repeated filename collisions")
check(ImportStorage.stagedFile(root: root, returnedName: file.path) == file, "accept absolute download callback inside staging")
check(ImportStorage.stagedFile(root: root, returnedName: "IMG_1.HEIC") == file, "accept relative download callback")
check(ImportStorage.stagedFile(root: root, returnedName: "../outside") == nil, "reject escaped download path")
let link = root.appendingPathComponent("escape")
try fm.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc"))
check(ImportStorage.stagedFile(root: root, returnedName: "escape/passwd") == nil, "reject symlink escape")
let key = ImportStorage.key(device: "A", path: "DCIM/100/IMG_1.HEIC", size: 3, date: nil)
check(key != ImportStorage.key(device: "B", path: "DCIM/100/IMG_1.HEIC", size: 3, date: nil), "distinguish two iPhones")
check(key != ImportStorage.key(device: "A", path: "DCIM/101/IMG_1.HEIC", size: 3, date: nil), "distinguish repeated camera filenames")
var history = ImportHistory()
history.files[key] = ImportRecord(relativePath: "IMG_1.HEIC", bytes: 3, importedAt: Date())
try history.save(to: root)
history = try ImportHistory.load(from: root)
check(history.alreadyImported(key, root: root), "persist verified completed copy")
try Data([1]).write(to: file)
check(!history.alreadyImported(key, root: root), "reimport when copy size changed")
try fm.removeItem(at: file)
check(!history.alreadyImported(key, root: root), "reimport when copy is missing")
try Data("broken json".utf8).write(to: ImportHistory.url(in: root))
var rejected = false
do { _ = try ImportHistory.load(from: root) } catch { rejected = true }
check(rejected, "surface damaged history instead of silently overwriting it")
check(ImportStorage.month(nil) == "Без даты", "handle missing capture date")
let firstConnection = USBDeviceIdentity(persistentID: "phone", uuid: nil, serial: nil, location: 1)
check(firstConnection.matches(USBDeviceIdentity(persistentID: "phone", uuid: "new", serial: nil, location: 2)), "follow replacement driver object by persistent identity")
check(firstConnection.matches(USBDeviceIdentity(persistentID: nil, uuid: nil, serial: nil, location: 1)), "replace placeholder using physical USB location")
check(!firstConnection.matches(USBDeviceIdentity(persistentID: "other", uuid: nil, serial: nil, location: 2)), "keep separate connected phones separate")
check(!USBDeviceIdentity(persistentID: nil, uuid: nil, serial: nil, location: 0).matches(USBDeviceIdentity(persistentID: nil, uuid: nil, serial: nil, location: 0)), "unknown identifiers never collapse unrelated devices")
print("\(checks) checks passed")
