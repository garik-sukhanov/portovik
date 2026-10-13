import Foundation

/// Как показать процесс: понятное имя, значок, подсказка.
struct Flavor {
    var title: String?
    var detail: String?
    var badge: (String, Double)?
    var hint: String?
}

enum Classifier {
    // MARK: Приложения

    /// Самый внешний .app в пути: …/Docker.app/Contents/MacOS/com.docker.backend → …/Docker.app
    static func appBundle(for path: String?) -> String? {
        guard let path else { return nil }
        // Инструменты Xcode (python3, git…) и Python.app внутри Python.framework — не приложения.
        if path.contains("/Contents/Developer/") { return nil }
        guard let r = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        let prefix = path[..<r.lowerBound]
        if prefix.contains(".framework/") { return nil }
        return String(prefix) + ".app"
    }

    /// Интерпретаторы внутри чужих .app (java из IntelliJ, node из редактора) группируем по проекту, а не по приложению.
    static func isInterpreter(_ exe: String) -> Bool {
        let l = exe.lowercased()
        return l.hasPrefix("python") || ["node", "ruby", "java", "php", "perl", "bun", "deno"].contains(l)
    }

    private static var appNames: [String: String] = [:]
    private static var mainExecutables: [String: String] = [:]
    private static var bundleIDs: [String: String] = [:]
    private static let lock = NSLock()

    static func appName(_ bundle: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if let n = appNames[bundle] { return n }
        var name = FileManager.default.displayName(atPath: bundle)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        appNames[bundle] = name
        return name
    }

    static func bundleID(_ bundle: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let id = bundleIDs[bundle] { return id.isEmpty ? nil : id }
        let id = Bundle(path: bundle)?.bundleIdentifier ?? ""
        bundleIDs[bundle] = id
        return id.isEmpty ? nil : id
    }

    /// Это главный исполняемый файл приложения, а не вспомогательный процесс внутри него.
    static func isMainExecutable(_ path: String, of bundle: String) -> Bool {
        lock.lock()
        let cached = mainExecutables[bundle]
        lock.unlock()
        let main: String
        if let cached { main = cached } else {
            main = Bundle(path: bundle)?.executableURL?.resolvingSymlinksInPath().path ?? ""
            lock.lock(); mainExecutables[bundle] = main; lock.unlock()
        }
        return !main.isEmpty && URL(fileURLWithPath: path).resolvingSymlinksInPath().path == main
    }

    static func isSystem(path: String?, uid: uid_t) -> Bool {
        guard let p = path else { return uid == 0 }
        let prefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]
        return prefixes.contains { p.hasPrefix($0) }
    }

    static let dockerBundles = ["Docker.app", "OrbStack.app", "Rancher Desktop.app", "Podman Desktop.app"]
    static let dockerExecutables: Set<String> = [
        "com.docker.backend", "com.docker.vpnkit", "vpnkit-bridge", "com.docker.build",
        "OrbStack Helper", "limactl", "gvproxy", "rancher-desktop",
    ]

    static func isDockerEngine(exe: String, bundle: String?) -> Bool {
        if dockerExecutables.contains(exe) { return true }
        guard let bundle else { return false }
        return dockerBundles.contains { bundle.hasSuffix("/" + $0) }
    }

    static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "tcsh", "csh", "ksh", "nu", "tmux", "screen", "-zsh", "-bash"]

    // MARK: Проекты

    private static var projectRoots: [String: String?] = [:]
    private static let markers = [".git", "package.json", "pyproject.toml", "requirements.txt", "Cargo.toml",
                                  "go.mod", "composer.json", "Gemfile", "pom.xml", "build.gradle", "build.gradle.kts",
                                  "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml",
                                  "deno.json", "Package.swift", "mix.exs", "manage.py"]

    /// Корень проекта для рабочей папки процесса: самый внешний каталог с .git, иначе ближайший с маркером.
    static func projectRoot(for cwd: String?) -> String? {
        guard let cwd, cwd != "/" else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard cwd != home, cwd.hasPrefix("/") else { return nil }
        lock.lock()
        if let cached = projectRoots[cwd] { lock.unlock(); return cached }
        lock.unlock()

        let fm = FileManager.default
        var nearest: String?
        var outermostGit: String?
        var dir = cwd
        var depth = 0
        while dir != "/", dir != home, depth < 12 {
            if fm.fileExists(atPath: dir + "/.git") { outermostGit = dir }
            if nearest == nil, markers.contains(where: { fm.fileExists(atPath: dir + "/" + $0) }) { nearest = dir }
            dir = (dir as NSString).deletingLastPathComponent
            depth += 1
        }
        // Системные и служебные папки (Homebrew, временные, ~/Library) проектом не считаем.
        let ignored = ["/private/", "/tmp/", "/var/", "/Library/", "/System/", "/Applications/", "/opt/", "/usr/",
                       home + "/Library/", home + "/."]
        var root = outermostGit ?? nearest
        if let r = root, ignored.contains(where: { r.hasPrefix($0) }) { root = nil }
        lock.lock(); projectRoots[cwd] = root; lock.unlock()
        return root
    }

    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    // MARK: Что это за процесс

    private static func mentions(_ args: [String], _ names: [String]) -> Bool {
        for a in args {
            for n in names {
                if a == n || a.hasSuffix("/" + n) || a.contains("/node_modules/\(n)/")
                    || a.contains("/node_modules/.bin/\(n)") || a.contains("/bin/\(n)") { return true }
            }
        }
        return false
    }

    /// Первый аргумент-скрипт, пропуская флаги вида `--import tsx`, `-r dotenv/config`.
    private static func scriptName(_ args: [String]) -> String? {
        let withValue: Set<String> = ["--import", "-r", "--require", "--loader", "--experimental-loader",
                                      "-e", "--eval", "-c", "-m", "-W", "-X", "--env-file", "--conditions", "-C"]
        var skipNext = false
        for a in args.dropFirst() {
            if skipNext { skipNext = false; continue }
            if withValue.contains(a) { skipNext = true; continue }
            if a.hasPrefix("-") || a.isEmpty { continue }
            if ["tsx", "ts-node", "nodemon", "ts-node-dev"].contains((a as NSString).lastPathComponent) { continue }
            return (a as NSString).lastPathComponent
        }
        return nil
    }

    static func flavor(exe: String, args: [String], bundle: String?) -> Flavor {
        let lower = exe.lowercased()
        let rest = Array(args.dropFirst())

        // JavaScript
        if ["node", "nodejs", "bun", "deno"].contains(lower) {
            let runtime = lower == "bun" ? "Bun" : lower == "deno" ? "Deno" : "Node.js"
            let tools: [([String], String)] = [
                (["vite"], "Vite"), (["next"], "Next.js"), (["nest", "@nestjs/cli"], "NestJS"),
                (["react-scripts"], "Create React App"), (["webpack", "webpack-dev-server"], "webpack"),
                (["nuxt", "nuxi"], "Nuxt"), (["astro"], "Astro"), (["@remix-run", "remix"], "Remix"),
                (["svelte-kit", "@sveltejs/kit"], "SvelteKit"), (["ng", "@angular/cli"], "Angular"),
                (["storybook", "start-storybook"], "Storybook"), (["expo"], "Expo"),
                (["react-native", "metro"], "Metro (React Native)"), (["gatsby"], "Gatsby"),
                (["parcel"], "Parcel"), (["nodemon"], "nodemon"), (["ts-node", "ts-node-dev"], "ts-node"),
                (["tsx"], "tsx"), (["json-server"], "json-server"), (["http-server"], "http-server"),
                (["live-server"], "live-server"), (["serve"], "serve"), (["prisma"], "Prisma"),
                (["vue-cli-service", "@vue/cli-service"], "Vue CLI"), (["wrangler"], "Wrangler"),
                (["firebase", "firebase-tools"], "Firebase"), (["turbo"], "Turborepo"),
                (["vitest"], "Vitest"), (["jest"], "Jest"), (["electron"], "Electron"),
                (["mcp-remote"], "MCP"), (["playwright"], "Playwright"),
            ]
            // Запускалки скриптов: важнее сам скрипт, а не tsx/nodemon.
            for runner in ["tsx", "ts-node", "ts-node-dev", "nodemon"] where mentions(rest, [runner]) {
                if let script = scriptName(args) {
                    return Flavor(title: script, detail: "\(runner) · \(runtime)", badge: ("TS", 0.58))
                }
            }
            for (names, title) in tools where mentions(rest, names) {
                return Flavor(title: title, detail: runtime, badge: ("JS", 0.30))
            }
            return Flavor(title: scriptName(args) ?? runtime, detail: runtime, badge: ("JS", 0.30))
        }

        // Python
        if lower.hasPrefix("python") {
            if let m = rest.firstIndex(of: "-m"), m + 1 < rest.count {
                let mod = rest[m + 1]
                let known = ["http.server": "Python http.server", "uvicorn": "Uvicorn", "flask": "Flask",
                             "django": "Django", "gunicorn": "Gunicorn", "jupyter": "Jupyter",
                             "streamlit": "Streamlit", "mkdocs": "MkDocs", "hypercorn": "Hypercorn",
                             "fastapi": "FastAPI", "celery": "Celery", "pip": "pip", "debugpy": "debugpy"]
                return Flavor(title: known[mod] ?? "python -m \(mod)", detail: "Python", badge: ("Py", 0.58))
            }
            let tools: [([String], String)] = [
                (["uvicorn"], "Uvicorn"), (["gunicorn"], "Gunicorn"), (["flask"], "Flask"),
                (["jupyter", "jupyter-lab", "jupyter-notebook"], "Jupyter"), (["streamlit"], "Streamlit"),
                (["mkdocs"], "MkDocs"), (["hypercorn"], "Hypercorn"), (["daphne"], "Daphne"),
                (["fastapi"], "FastAPI"), (["celery"], "Celery"), (["gradio"], "Gradio"),
            ]
            for (names, title) in tools where mentions(rest, names) {
                return Flavor(title: title, detail: "Python", badge: ("Py", 0.58))
            }
            if rest.contains(where: { $0.hasSuffix("manage.py") }), rest.contains("runserver") {
                return Flavor(title: "Django", detail: "manage.py runserver", badge: ("Py", 0.58))
            }
            return Flavor(title: "Python", detail: scriptName(args), badge: ("Py", 0.58))
        }

        switch lower {
        case "ruby":
            let tools: [([String], String)] = [(["rails"], "Rails"), (["puma"], "Puma"), (["jekyll"], "Jekyll"),
                                                (["rackup"], "Rack"), (["sidekiq"], "Sidekiq")]
            for (names, title) in tools where mentions(rest, names) {
                return Flavor(title: title, detail: "Ruby", badge: ("Rb", 0.0))
            }
            return Flavor(title: "Ruby", detail: scriptName(args), badge: ("Rb", 0.0))
        case "puma", "rails":
            return Flavor(title: lower == "puma" ? "Puma" : "Rails", detail: "Ruby", badge: ("Rb", 0.0))
        case "php", "php-fpm":
            if rest.contains("artisan") { return Flavor(title: "Laravel", detail: "php artisan serve", badge: ("PHP", 0.70)) }
            if rest.contains("-S") { return Flavor(title: "PHP-сервер", detail: "php -S", badge: ("PHP", 0.70)) }
            return Flavor(title: lower == "php-fpm" ? "PHP-FPM" : "PHP", detail: scriptName(args), badge: ("PHP", 0.70))
        case "java":
            if let j = rest.firstIndex(of: "-jar"), j + 1 < rest.count {
                return Flavor(title: (rest[j + 1] as NSString).lastPathComponent, detail: "Java", badge: ("Jv", 0.07))
            }
            if rest.contains(where: { $0.contains("GradleDaemon") || $0.contains("org.gradle") }) {
                return Flavor(title: "Gradle daemon", detail: "Java", badge: ("Jv", 0.07))
            }
            if rest.contains(where: { $0.contains("elasticsearch") }) {
                return Flavor(title: "Elasticsearch", detail: "Java", badge: ("ES", 0.13))
            }
            let main = rest.last(where: { !$0.hasPrefix("-") && !$0.contains("/") && $0.contains(".") })
            return Flavor(title: main.map { String($0.split(separator: ".").last ?? Substring($0)) } ?? "Java",
                          detail: "Java", badge: ("Jv", 0.07))
        case "dotnet":
            return Flavor(title: scriptName(args) ?? ".NET", detail: ".NET", badge: (".N", 0.75))
        case "beam.smp":
            if rest.contains(where: { $0.contains("rabbit") }) { return Flavor(title: "RabbitMQ", detail: "Erlang", badge: ("Rq", 0.08)) }
            return Flavor(title: "Erlang/Elixir", detail: nil, badge: ("Ex", 0.78))
        case "postgres", "postmaster":
            return Flavor(title: "PostgreSQL", detail: dataDir(rest), badge: ("PG", 0.60))
        case "mysqld", "mysqld_safe":
            return Flavor(title: "MySQL", detail: nil, badge: ("My", 0.55))
        case "mariadbd":
            return Flavor(title: "MariaDB", detail: nil, badge: ("Ma", 0.55))
        case "mongod", "mongos":
            return Flavor(title: "MongoDB", detail: nil, badge: ("Mg", 0.36))
        case "redis-server":
            return Flavor(title: "Redis", detail: nil, badge: ("Rd", 0.0))
        case "valkey-server":
            return Flavor(title: "Valkey", detail: nil, badge: ("Vk", 0.95))
        case "memcached":
            return Flavor(title: "Memcached", detail: nil, badge: ("Mc", 0.4))
        case "nginx":
            return Flavor(title: "nginx", detail: nil, badge: ("nx", 0.38))
        case "httpd":
            return Flavor(title: "Apache", detail: nil, badge: ("Ap", 0.9))
        case "caddy":
            return Flavor(title: "Caddy", detail: nil, badge: ("Cd", 0.45))
        case "traefik":
            return Flavor(title: "Traefik", detail: nil, badge: ("Tr", 0.52))
        case "minio":
            return Flavor(title: "MinIO", detail: nil, badge: ("Mi", 0.98))
        case "ollama":
            return Flavor(title: "Ollama", detail: "локальные LLM", badge: ("Ol", 0.0))
        case "adb":
            return Flavor(title: "ADB", detail: "Android Debug Bridge", badge: ("adb", 0.33),
                          hint: "Сервер отладки Android — его запускают Android Studio и `adb`. Порт 5037 нужен для связи с устройствами.")
        case "ssh":
            if let l = rest.firstIndex(of: "-L"), l + 1 < rest.count {
                let host = rest.last(where: { !$0.hasPrefix("-") }) ?? ""
                return Flavor(title: "SSH-туннель", detail: "\(rest[l + 1]) → \(host)", badge: ("ssh", 0.0),
                              hint: "Проброс порта через SSH: локальный порт ведёт на удалённый сервер.")
            }
            return Flavor(title: "SSH", detail: rest.last(where: { !$0.hasPrefix("-") }), badge: ("ssh", 0.0))
        case "kubectl":
            if rest.contains("port-forward") {
                return Flavor(title: "kubectl port-forward", detail: rest.last, badge: ("k8s", 0.6))
            }
            return Flavor(title: "kubectl", detail: nil, badge: ("k8s", 0.6))
        case "com.docker.backend":
            return Flavor(title: "Docker Desktop", detail: "движок Docker",
                          hint: "Порты опубликованных контейнеров открывает Docker Desktop. Чтобы освободить порт, останавливайте контейнер, а не этот процесс.")
        case "controlcenter":
            return Flavor(title: nil, detail: "приёмник AirPlay",
                          hint: "Порты 5000 и 7000 держит приёмник AirPlay. Если они нужны dev-серверу (Flask, AirPlay-конфликт — классика), отключите: Системные настройки → Основные → AirDrop и Handoff → «Приёмник AirPlay».")
        case "rapportd":
            return Flavor(title: nil, detail: "Continuity / Handoff",
                          hint: "Служба macOS для связи с другими устройствами Apple (Handoff, универсальный буфер обмена).")
        case "sharingd":
            return Flavor(title: nil, detail: "AirDrop и общий доступ", hint: nil)
        case "mdnsresponder":
            return Flavor(title: nil, detail: "Bonjour и DNS", hint: nil)
        case "launchd":
            return Flavor(title: nil, detail: "системный загрузчик служб", hint: "launchd сам открывает сокеты для служб, которые запускаются по требованию.")
        default:
            break
        }
        return Flavor()
    }

    private static func dataDir(_ args: [String]) -> String? {
        if let d = args.firstIndex(of: "-D"), d + 1 < args.count { return Classifier.abbreviate(args[d + 1]) }
        return nil
    }
}
