import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage(Prefs.interval) private var interval = 2.0
    @AppStorage(Prefs.showUDP) private var showUDP = false
    @AppStorage(Prefs.showSystem) private var showSystem = true
    @AppStorage(Prefs.showClients) private var showClients = true
    @AppStorage(Prefs.deepScan) private var deepScan = true
    @AppStorage(Prefs.linkMemory) private var linkMemory = 60.0
    @AppStorage(Prefs.showMenuBar) private var showMenuBar = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Обновление") {
                Picker("Обновлять каждые", selection: $interval) {
                    Text("1 секунду").tag(1.0)
                    Text("2 секунды").tag(2.0)
                    Text("5 секунд").tag(5.0)
                    Text("10 секунд").tag(10.0)
                }
                Picker("Помнить связь после разрыва", selection: $linkMemory) {
                    Text("не помнить").tag(0.0)
                    Text("30 секунд").tag(30.0)
                    Text("1 минуту").tag(60.0)
                    Text("5 минут").tag(300.0)
                }
                Text("Короткие HTTP-запросы живут доли секунды — память связей не даёт им мигать на схеме.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Что показывать") {
                Toggle("Службы macOS", isOn: $showSystem)
                Toggle("UDP-порты", isOn: $showUDP)
                Toggle("Клиентов на схеме (браузеры, приложения)", isOn: $showClients)
            }
            Section("Docker") {
                Toggle("Видеть связи внутри Docker", isOn: $deepScan)
                Text("Раз в несколько секунд Портовик читает /proc/net/tcp в каждом контейнере через docker exec — так видно, что web ходит в db. В контейнерах без утилиты cat это не сработает.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Строка меню") {
                Toggle("Значок в строке меню", isOn: $showMenuBar)
                Toggle("Запускать при входе в систему", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Text("Пока значок включён, Портовик продолжает работать после закрытия окна. Для автозапуска лучше держать приложение в папке «Программы».")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
