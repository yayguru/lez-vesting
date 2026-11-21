#include "vesting_module_impl.h"
#include "run_process.h"

#include <fstream>
#include <chrono>
#include <thread>
#include <sstream>

namespace {
#ifdef _WIN32
const char kSep = '\\';
const char* kCli = "vesting.exe";
#else
const char kSep = '/';
const char* kCli = "vesting";
#endif

std::string jsonEscape(const std::string& s) {
    std::string o;
    for (unsigned char c : s) {
        switch (c) {
            case '"': o += "\\\""; break;
            case '\\': o += "\\\\"; break;
            case '\n': o += "\\n"; break;
            case '\r': o += "\\r"; break;
            case '\t': o += "\\t"; break;
            default:
                if (c < 0x20) { char b[8]; snprintf(b, sizeof b, "\\u%04x", c); o += b; } else o += (char)c;
        }
    }
    return o;
}
std::string error(const std::string& msg) { return "{\"ok\":false,\"error\":\"" + jsonEscape(msg) + "\"}"; }

// Flat {"k":"v",...} reader for our own config file and setConfig input (strings and booleans only).
std::map<std::string, std::string> parseFlat(const std::string& j) {
    std::map<std::string, std::string> m;
    size_t i = 0;
    auto skip = [&] { while (i < j.size() && (isspace((unsigned char)j[i]) || j[i] == ',' || j[i] == '{' || j[i] == '}')) ++i; };
    auto str = [&]() -> std::string {
        std::string s; ++i;
        while (i < j.size() && j[i] != '"') { if (j[i] == '\\' && i + 1 < j.size()) ++i; s += j[i++]; }
        ++i; return s;
    };
    while (true) {
        skip();
        if (i >= j.size() || j[i] != '"') break;
        std::string k = str();
        while (i < j.size() && (isspace((unsigned char)j[i]) || j[i] == ':')) ++i;
        std::string v;
        if (i < j.size() && j[i] == '"') v = str();
        else { while (i < j.size() && j[i] != ',' && j[i] != '}' && !isspace((unsigned char)j[i])) v += j[i++]; }
        m[k] = v;
    }
    return m;
}
bool validId(const std::string& s, size_t minLen, size_t maxLen) {
    if (s.size() < minLen || s.size() > maxLen) return false;
    for (char c : s) if (!isalnum((unsigned char)c)) return false;
    return true;
}
}  // namespace

std::string VestingModuleImpl::configPath() {
    std::string base = instancePersistencePath();
    if (base.empty()) base = ".";
    return base + kSep + "vesting_module.json";
}

std::map<std::string, std::string> VestingModuleImpl::settings() {
    std::map<std::string, std::string> s;
    std::string mod = modulePath();
    s["cli"] = (mod.empty() ? std::string(".") : mod) + kSep + kCli;
    std::string base = instancePersistencePath();
    s["wallet_home"] = (base.empty() ? std::string(".") : base) + kSep + "wallet";
    s["program"] = "";
    s["dev_mode"] = "false";
    s["backend"] = "native";      // "native": run `cli` directly; "wsl": run it inside WSL
    s["wsl_distro"] = "";         // optional distro name for the wsl backend
#ifdef _WIN32
    // No native Windows CLI shipped (r0vm has no Windows build yet): default to WSL.
    if (!std::ifstream(s["cli"])) { s["backend"] = "wsl"; s["cli"] = "vesting"; }
#endif
    std::ifstream f(configPath());
    if (f) {
        std::stringstream ss; ss << f.rdbuf();
        for (auto& [k, v] : parseFlat(ss.str())) s[k] = v;
    }
    return s;
}

std::string VestingModuleImpl::getConfig() {
    auto s = settings();
    std::string o = "{\"ok\":true";
    for (auto& [k, v] : s) o += ",\"" + jsonEscape(k) + "\":\"" + jsonEscape(v) + "\"";
    return o + "}";
}

std::string VestingModuleImpl::setConfig(const std::string& json) {
    auto s = settings();
    for (auto& [k, v] : parseFlat(json)) {
        if (k == "backend" && v != "native" && v != "wsl") return error("backend must be native or wsl");
        if (k == "cli" || k == "wallet_home" || k == "program" || k == "dev_mode" || k == "backend" || k == "wsl_distro") s[k] = v;
        else return error("unknown setting: " + k);
    }
    std::ofstream f(configPath(), std::ios::trunc);
    if (!f) return error("cannot write " + configPath());
    f << "{";
    bool first = true;
    for (auto& [k, v] : s) { f << (first ? "" : ",") << "\"" << jsonEscape(k) << "\":\"" << jsonEscape(v) << "\""; first = false; }
    f << "}\n";
    f.close();   // flush before getConfig() reads it back
    if (!f) return error("cannot write " + configPath());
    return getConfig();
}

std::string VestingModuleImpl::run(std::vector<std::string> args, bool isRead) {
    auto s = settings();
    if (s["program"].empty() && args[0] != "accounts") return error("set the vesting program id first (setConfig {\"program\":\"...\"})");
    std::vector<std::string> tail{"--json"};
    if (!s["program"].empty()) { tail.push_back("--program"); tail.push_back(s["program"]); }
    tail.insert(tail.end(), args.begin(), args.end());
    std::vector<std::string> argv;
    std::vector<std::pair<std::string, std::string>> env;
    if (s["backend"] == "wsl") {
        // Windows host, CLI and wallet inside WSL (RISC0 r0vm has no native Windows build yet).
        // `cli` and `wallet_home` are Linux paths there; env is passed through env(1).
#ifdef _WIN32
        argv.push_back("C:\\Windows\\System32\\wsl.exe");
#else
        argv.push_back("/usr/bin/wsl.exe");
#endif
        if (!s["wsl_distro"].empty()) { argv.push_back("-d"); argv.push_back(s["wsl_distro"]); }
        argv.insert(argv.end(), {"-e", "env"});
        // A Windows-style default (C:\..., module data dir) means "not set": use the wallet's own default home.
        const std::string& wh = s["wallet_home"];
        if (!wh.empty() && wh.find(':') == std::string::npos && wh.find('\\') == std::string::npos)
            argv.push_back("LEE_WALLET_HOME_DIR=" + wh);
        if (s["dev_mode"] == "true") argv.push_back("RISC0_DEV_MODE=1");
        const std::string& cli = s["cli"];
        bool winPath = cli.size() >= 4 && (cli.compare(cli.size() - 4, 4, ".exe") == 0 || cli.find(':') != std::string::npos);
        argv.push_back(winPath ? std::string("vesting") : cli);   // default: `vesting` on the WSL PATH
    } else {
        argv.push_back(s["cli"]);
        env.push_back({"LEE_WALLET_HOME_DIR", s["wallet_home"]});
        if (s["dev_mode"] == "true") env.push_back({"RISC0_DEV_MODE", "1"});
    }
    argv.insert(argv.end(), tail.begin(), tail.end());
    // Reads give up before the bridge call times out; sends (in job threads) wait their turn.
    std::unique_lock<std::timed_mutex> guard(m_cliLock, std::defer_lock);
    if (isRead) {
        if (!guard.try_lock_for(std::chrono::seconds(12)))
            return error("V022 busy: a transaction is still being proved or included; try again in a moment");
    } else {
        guard.lock();
    }
    auto [code, out] = runProcess(argv, env);
    if (code == -1) return error("cannot start " + argv[0] + (s["backend"] == "wsl" ? " (is WSL installed?)" : ""));
    if (s["backend"] == "wsl" && code != 0 && out.find('{') == std::string::npos)
        return error("WSL could not run " + s["cli"] + " (exit " + std::to_string(code) + "); check that WSL has a distro with the vesting CLI at that path");
    while (!out.empty() && (out.back() == '\n' || out.back() == '\r')) out.pop_back();
    size_t nl = out.rfind('\n');
    std::string last = nl == std::string::npos ? out : out.substr(nl + 1);
    if (last.empty() || last[0] != '{') return error("vesting CLI exited " + std::to_string(code) + " without a result");
    return last;
}

std::string VestingModuleImpl::startJob(std::vector<std::string> args) {
    auto slot = std::make_shared<std::string>();
    std::string id;
    {
        std::lock_guard<std::mutex> g(m_jobsLock);
        id = std::to_string(m_nextJob++);
        m_jobs[id] = slot;
    }
    std::thread([this, args, slot] {
        std::string r = run(args, false);
        std::lock_guard<std::mutex> g(m_jobsLock);
        *slot = r;
    }).detach();
    return "{\"ok\":true,\"pending\":true,\"job\":\"" + id + "\"}";
}

std::string VestingModuleImpl::jobResult(const std::string& job) {
    std::lock_guard<std::mutex> g(m_jobsLock);
    auto it = m_jobs.find(job);
    if (it == m_jobs.end()) return error("unknown job " + job);
    if (it->second->empty()) return "{\"ok\":true,\"pending\":true,\"job\":\"" + jsonEscape(job) + "\"}";
    std::string r = *it->second;
    m_jobs.erase(it);
    return r;
}

std::string VestingModuleImpl::accounts() { return run({"accounts"}); }
std::string VestingModuleImpl::listSchedules() { return run({"list"}); }

std::string VestingModuleImpl::show(const std::string& creator, const std::string& id) {
    if (!validId(creator, 32, 48) || !validId(id, 64, 64)) return error("invalid creator or id");
    return run({"show", "--creator", creator, "--id", id});
}
std::string VestingModuleImpl::track(const std::string& creator, const std::string& id) {
    if (!validId(creator, 32, 48) || !validId(id, 64, 64)) return error("invalid creator or id");
    return run({"track", "--creator", creator, "--id", id});
}

std::string VestingModuleImpl::create(const std::string& creator, const std::string& beneficiary, const std::string& total,
                                      const std::string& kind, const std::string& values, bool cancelable, bool transferable) {
    if (!validId(creator, 32, 48) || !validId(beneficiary, 32, 48)) return error("invalid account id");
    for (char c : total) if (!isdigit((unsigned char)c)) return error("total must be a whole number");
    for (char c : values) if (!isdigit((unsigned char)c) && c != ',') return error("values must be comma-separated numbers");
    std::vector<std::string> a{"create", "--creator", creator, "--beneficiary", beneficiary, "--total", total};
    if (kind == "linear") { a.push_back("--linear"); a.push_back(values); }
    else if (kind == "milestones") { a.push_back("--milestones"); a.push_back(values); }
    else return error("kind must be linear or milestones");
    if (!cancelable) a.push_back("--non-cancelable");
    if (transferable) a.push_back("--transferable");
    return startJob(a);
}

std::string VestingModuleImpl::quoteClaim(const std::string& beneficiary, const std::string& creator, const std::string& id,
                                          const std::string& privateAccount) {
    if (!validId(beneficiary, 32, 48) || !validId(creator, 32, 48) || !validId(id, 64, 64)) return error("invalid input");
    std::vector<std::string> a{"claim", "--dry-run", "--beneficiary", beneficiary, "--creator", creator, "--id", id};
    if (!privateAccount.empty()) { if (!validId(privateAccount, 32, 48)) return error("invalid private account"); a.push_back("--private"); a.push_back(privateAccount); }
    return run(a);
}

std::string VestingModuleImpl::claim(const std::string& beneficiary, const std::string& creator, const std::string& id,
                                     const std::string& privateAccount) {
    if (!validId(beneficiary, 32, 48) || !validId(creator, 32, 48) || !validId(id, 64, 64)) return error("invalid input");
    std::vector<std::string> a{"claim", "--yes", "--beneficiary", beneficiary, "--creator", creator, "--id", id};
    if (!privateAccount.empty()) { if (!validId(privateAccount, 32, 48)) return error("invalid private account"); a.push_back("--private"); a.push_back(privateAccount); }
    return startJob(a);
}

std::string VestingModuleImpl::receivePending() { return startJob({"receive"}); }

std::string VestingModuleImpl::cancel(const std::string& creator, const std::string& id) {
    if (!validId(creator, 32, 48) || !validId(id, 64, 64)) return error("invalid creator or id");
    return startJob({"cancel", "--creator", creator, "--id", id});
}

std::string VestingModuleImpl::signalMilestone(const std::string& creator, const std::string& id, int64_t index) {
    if (!validId(creator, 32, 48) || !validId(id, 64, 64) || index < 0 || index > 63) return error("invalid input");
    return startJob({"signal", "--creator", creator, "--id", id, "--index", std::to_string(index)});
}

std::string VestingModuleImpl::makeIrrevocable(const std::string& creator, const std::string& id) {
    if (!validId(creator, 32, 48) || !validId(id, 64, 64)) return error("invalid creator or id");
    return startJob({"irrevocable", "--creator", creator, "--id", id});
}

std::string VestingModuleImpl::transferBeneficiary(const std::string& beneficiary, const std::string& creator, const std::string& id,
                                                   const std::string& newBeneficiary) {
    if (!validId(beneficiary, 32, 48) || !validId(creator, 32, 48) || !validId(id, 64, 64) || !validId(newBeneficiary, 32, 48))
        return error("invalid input");
    return startJob({"transfer-beneficiary", "--beneficiary", beneficiary, "--creator", creator, "--id", id,
                     "--new-beneficiary", newBeneficiary});
}

std::string VestingModuleImpl::createBatch(const std::string& creator, const std::string& entriesJson) {
    if (!validId(creator, 32, 48)) return error("invalid creator");
    if (entriesJson.empty() || entriesJson.size() > 200000) return error("entries must be a non-empty JSON array");
    static const char* hexd = "0123456789abcdef";
    std::string hex;
    hex.reserve(entriesJson.size() * 2);
    for (unsigned char ch : entriesJson) { hex.push_back(hexd[ch >> 4]); hex.push_back(hexd[ch & 15]); }
    return startJob({"create-batch", "--creator", creator, "--entries-hex", hex});
}
