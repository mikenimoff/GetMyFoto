import SwiftUI
import AppKit

enum AppVersion {
    static var number: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1" }
    static var display: String { "\(number) (\(build))" }
}

struct DeleteReview: Identifiable {
    let id = UUID()
    let items: [MediaItem]
    let deviceName: String
    let deviceIdentity: ObjectIdentifier
}

struct AppView: View {
    @ObservedObject var model: DeviceModel
    @State private var search = ""
    @State private var filter = "Все"
    @State private var review: DeleteReview?
    @State private var showReport = false
    private let accent = Color(red: 0.12, green: 0.52, blue: 0.41)

    private var visible: [MediaItem] {
        model.items.filter { (filter == "Все" || $0.kind == filter) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                library
                Divider()
                destination
                Divider()
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(minWidth: 960, minHeight: 690)
        .tint(accent)
        .sheet(item: $review) { value in DeleteSheet(model: model, review: value) }
        .sheet(isPresented: $showReport) { reportSheet }
        .alert("GetMyFoto", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("Понятно", role: .cancel) { model.alert = nil }
        } message: { Text(model.alert ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("GetMyFoto").font(.system(size: 19, weight: .bold))
                    Text("С iPhone на Mac").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("УСТРОЙСТВО").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                if model.devices.isEmpty {
                    Label("Нет подключения", systemImage: "iphone.slash").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.devices.enumerated()), id: \.offset) { _, device in
                        Button { model.connect(device) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "iphone").font(.system(size: 20))
                                Text(DeviceModel.displayName(device)).lineLimit(2)
                                Spacer()
                                if model.camera === device { Circle().fill(accent).frame(width: 7, height: 7) }
                            }
                            .padding(10)
                            .background(model.camera === device ? accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).disabled(model.busy)
                    }
                }
                Button(action: model.reconnect) { Label("Обновить", systemImage: "arrow.clockwise") }.disabled(model.busy)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 17) {
                Text("ТРИ ПРОСТЫХ ШАГА").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                step("1", "Подключите кабель", "Разблокируйте iPhone и разрешите доступ.")
                step("2", "Выберите файлы", "Фото, видео или всю доступную медиатеку.")
                step("3", "Сохраните на Mac", "Укажите папку и начните копирование.")
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Label("Передача по USB", systemImage: "cable.connector").font(.system(size: 12, weight: .medium))
                Text("Версия \(AppVersion.display)").font(.system(size: 11)).foregroundStyle(.secondary)
                Link("Проект на GitHub ↗", destination: URL(string: "https://github.com/mikenimoff/GetMyFoto")!).font(.system(size: 11))
            }
        }
        .padding(24)
        .frame(width: 240)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func step(_ number: String, _ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number).font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                .frame(width: 22, height: 22).background(accent.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Ваши кадры. На вашем Mac.").font(.system(size: 25, weight: .semibold))
                    Text("Фото и видео с iPhone в обычную папку.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("USB").font(.system(size: 11, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(accent.opacity(0.10), in: Capsule()).foregroundStyle(accent)
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.busy ? "arrow.triangle.2.circlepath" : model.ready ? "checkmark.circle.fill" : "cable.connector")
                    .foregroundStyle(accent).font(.system(size: 18)).frame(width: 23)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.status).font(.system(size: 13, weight: .medium))
                    Text(model.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
            }
            if model.busy { ProgressView(value: model.fraction).progressViewStyle(.linear) }
        }
        .padding(24)
    }

    private var library: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Тип", selection: $filter) {
                    ForEach(["Все", "Фото", "Видео", "Другое"], id: \.self) { Text($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 270)
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Поиск по имени", text: $search).textFieldStyle(.plain)
                }.padding(7).background(Color(nsColor: .quaternaryLabelColor).opacity(0.13), in: RoundedRectangle(cornerRadius: 7))
                .frame(maxWidth: 220)
            }.padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 12)
            HStack(spacing: 12) {
                Button(visible.allSatisfy { model.selected.contains($0.id) } && !visible.isEmpty ? "Снять выбор" : "Выбрать все") {
                    let ids = Set(visible.map(\.id))
                    if ids.isSubset(of: model.selected) { model.selected.subtract(ids) } else { model.selected.formUnion(ids) }
                }.disabled(!model.ready || model.busy || visible.isEmpty)
                Button("Только сохранённые") { model.selected = Set(visible.filter { model.knownImported.contains($0.id) }.map(\.id)) }
                    .disabled(!model.ready || model.busy || model.knownImported.isEmpty)
                    .help("Выбрать файлы, скопированные GetMyFoto в текущую папку. Проверяется наличие и размер копии.")
                Spacer()
                Text("\(visible.count) файлов").font(.system(size: 11)).foregroundStyle(.secondary)
            }.buttonStyle(.link).font(.system(size: 12)).padding(.horizontal, 24).padding(.bottom, 12)
            if model.items.isEmpty {
                Spacer(minLength: 10)
                VStack(spacing: 13) {
                    Image(systemName: "iphone.and.arrow.forward").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(accent)
                    Text(model.camera == nil ? "Начните с подключения iPhone" : model.ready ? "Нет доступных файлов" : "Ожидаем доступ к медиатеке")
                        .font(.system(size: 17, weight: .medium))
                    Text("Используйте кабель с передачей данных.\nНа iPhone подтвердите доверие к этому Mac.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if model.camera != nil && !model.ready { ProgressView().controlSize(.small) }
                }.padding(25)
                Spacer(minLength: 20)
            } else if visible.isEmpty {
                Spacer(); Text("Ничего не найдено").foregroundStyle(.secondary); Spacer()
            } else {
                List(visible) { item in
                    HStack(spacing: 12) {
                        Toggle("Выбрать \(item.name)", isOn: Binding(get: { model.selected.contains(item.id) }, set: { value in
                            if value { model.selected.insert(item.id) } else { model.selected.remove(item.id) }
                        })).labelsHidden().toggleStyle(.checkbox).disabled(model.busy || !model.ready)
                        Image(systemName: item.symbol).font(.system(size: 20)).foregroundStyle(accent)
                            .frame(width: 36, height: 36).background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            HStack(spacing: 7) {
                                Text(item.kind)
                                if let date = item.date { Text(date, style: .date) }
                                if model.knownImported.contains(item.id) { Label("Сохранён", systemImage: "checkmark.circle.fill").foregroundStyle(accent) }
                            }.font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(DeviceModel.size(item.bytes)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }.padding(.vertical, 3)
                }.listStyle(.inset).scrollContentBackground(.hidden)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 12) {
                Image(systemName: "folder").font(.system(size: 23)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Сохранить в папку").font(.system(size: 12, weight: .medium))
                    Text(model.folder?.path ?? "Выберите папку на Mac или внешнем диске").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer()
                Button(model.folder == nil ? "Выбрать…" : "Изменить…", action: model.chooseFolder).disabled(model.busy)
                Button { model.revealFolder() } label: { Image(systemName: "arrow.up.forward.square") }
                    .help("Открыть папку в Finder").disabled(model.folder == nil)
            }
            HStack(spacing: 18) {
                Toggle("Папки по месяцам", isOn: $model.byMonth)
                Toggle("Пропускать уже сохранённые", isOn: $model.skipImported)
            }.toggleStyle(.checkbox).font(.system(size: 11)).disabled(model.busy)
        }.padding(.horizontal, 24).padding(.vertical, 17)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Выбрано: \(model.selected.count)").font(.system(size: 12, weight: .medium))
                    Text(DeviceModel.size(model.chosenBytes)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if !model.report.isEmpty { Button { showReport = true } label: { Image(systemName: "doc.text") }.help("Отчёт об операции") }
                if model.busy {
                    Button(model.deleting ? "Остановить удаление" : model.stopping ? "Останавливаем…" : "Остановить после файла", action: model.stop)
                        .disabled(model.stopping)
                } else {
                    Button(role: .destructive) {
                        model.refreshImportStatus()
                        if let camera = model.camera {
                            review = DeleteReview(items: model.chosen, deviceName: DeviceModel.displayName(camera), deviceIdentity: ObjectIdentifier(camera))
                        }
                    } label: { Label("Удалить…", systemImage: "trash") }
                    .disabled(!model.canDelete).help("Удалить выбранные файлы с iPhone. Потребуется подтверждение.")
                    Button(action: model.importSelected) { Label("Скопировать на Mac", systemImage: "arrow.down.to.line") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(!model.ready || model.selected.isEmpty || model.folder == nil)
                }
            }
            Text("Live Photo может состоять из фото и видео — выберите обе части. Копирование не удаляет оригиналы.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.ready && !model.supportsDeletion {
                Text("Этот iPhone не разрешает удаление по USB. Очистить медиатеку можно в приложении «Фото» на телефоне.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 24).padding(.vertical, 18)
    }

    private var reportSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Отчёт").font(.title2.bold())
            ScrollView { Text(model.report).font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
            HStack {
                Button("Сохранить…") {
                    let panel = NSSavePanel(); panel.nameFieldStringValue = "GetMyFoto-report.txt"; panel.allowedContentTypes = [.plainText]
                    if panel.runModal() == .OK, let url = panel.url {
                        do { try model.report.write(to: url, atomically: true, encoding: .utf8) }
                        catch { model.alert = error.localizedDescription }
                    }
                }
                Spacer()
                Button("Закрыть") { showReport = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 620, height: 440)
    }
}

struct DeleteSheet: View {
    @ObservedObject var model: DeviceModel
    let review: DeleteReview
    @Environment(\.dismiss) var dismiss
    @State private var acknowledged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Удалить с iPhone?", systemImage: "trash").font(.system(size: 23, weight: .semibold)).foregroundStyle(.red)
            Text("\(review.deviceName) · \(review.items.count) файлов · \(DeviceModel.size(review.items.reduce(0) { $0 + $1.bytes }))")
                .font(.system(size: 13, weight: .medium))
            Text("Это удаление оригиналов с устройства. Если включены «Фото iCloud», изменения могут распространиться на iCloud и другие устройства. iOS может также удалить связанные части Live Photo. GetMyFoto не сможет отменить удаление.")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            let saved = review.items.filter { model.knownImported.contains($0.id) }.count
            Text("Копии в выбранной папке подтверждены для \(saved) из \(review.items.count) файлов (по наличию и размеру).")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(saved == review.items.count ? Color.secondary : .orange)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(review.items) { item in
                        HStack { Image(systemName: item.symbol); Text(item.name); Spacer(); Text(DeviceModel.size(item.bytes)).foregroundStyle(.secondary) }
                    }
                }.font(.system(size: 12)).padding(12)
            }.frame(height: 175).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            Toggle("Я проверил список и хочу удалить эти файлы", isOn: $acknowledged).toggleStyle(.checkbox)
            HStack {
                Button("Отмена", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Удалить \(review.items.count) файлов", role: .destructive) {
                    let frozen = review.items
                    dismiss()
                    model.deleteConfirmed(frozen, deviceIdentity: review.deviceIdentity)
                }.disabled(!acknowledged || !model.canDelete)
            }
        }.padding(26).frame(width: 550)
    }
}
