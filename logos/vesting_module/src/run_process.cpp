#include "run_process.h"

#ifdef _WIN32
#include <windows.h>

static std::wstring widen(const std::string& s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), w.data(), n);
    return w;
}

// Quote one argument for CommandLineToArgvW rules.
static std::wstring quoteArg(const std::wstring& a) {
    if (!a.empty() && a.find_first_of(L" \t\"") == std::wstring::npos) return a;
    std::wstring q = L"\"";
    size_t bs = 0;
    for (wchar_t c : a) {
        if (c == L'\\') { ++bs; continue; }
        if (c == L'"') { q.append(bs * 2 + 1, L'\\'); q += c; bs = 0; continue; }
        q.append(bs, L'\\'); bs = 0; q += c;
    }
    q.append(bs * 2, L'\\');
    q += L'"';
    return q;
}

std::pair<int, std::string> runProcess(const std::vector<std::string>& argv,
                                       const std::vector<std::pair<std::string, std::string>>& env) {
    for (const auto& [k, v] : env) SetEnvironmentVariableW(widen(k).c_str(), widen(v).c_str());
    SECURITY_ATTRIBUTES sa{sizeof(sa), nullptr, TRUE};
    HANDLE rd = nullptr, wr = nullptr;
    if (!CreatePipe(&rd, &wr, &sa, 0)) return {-1, ""};
    SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0);
    HANDLE nul = CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, OPEN_EXISTING, 0, nullptr);
    STARTUPINFOW si{}; si.cb = sizeof(si); si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdOutput = wr; si.hStdError = nul; si.hStdInput = nul;
    std::wstring cmd;
    for (const auto& a : argv) { if (!cmd.empty()) cmd += L' '; cmd += quoteArg(widen(a)); }
    PROCESS_INFORMATION pi{};
    BOOL ok = CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi);
    CloseHandle(wr);
    if (!ok) { CloseHandle(rd); CloseHandle(nul); return {-1, ""}; }
    std::string out; char buf[4096]; DWORD n = 0;
    while (ReadFile(rd, buf, sizeof(buf), &n, nullptr) && n > 0) out.append(buf, n);
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 1; GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess); CloseHandle(pi.hThread); CloseHandle(rd); CloseHandle(nul);
    return {(int)code, out};
}
#else
#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <cstdlib>

std::pair<int, std::string> runProcess(const std::vector<std::string>& argv,
                                       const std::vector<std::pair<std::string, std::string>>& env) {
    int fd[2];
    if (pipe(fd) != 0) return {-1, ""};
    pid_t pid = fork();
    if (pid < 0) { close(fd[0]); close(fd[1]); return {-1, ""}; }
    if (pid == 0) {
        dup2(fd[1], 1);
        int nul = open("/dev/null", O_RDWR);
        if (nul >= 0) { dup2(nul, 0); dup2(nul, 2); }
        close(fd[0]); close(fd[1]);
        for (const auto& [k, v] : env) setenv(k.c_str(), v.c_str(), 1);
        std::vector<char*> args;
        for (const auto& a : argv) args.push_back(const_cast<char*>(a.c_str()));
        args.push_back(nullptr);
        execv(args[0], args.data());
        _exit(127);
    }
    close(fd[1]);
    std::string out; char buf[4096]; ssize_t n;
    while ((n = read(fd[0], buf, sizeof(buf))) > 0) out.append(buf, (size_t)n);
    close(fd[0]);
    int st = 0; waitpid(pid, &st, 0);
    return {WIFEXITED(st) ? WEXITSTATUS(st) : -1, out};
}
#endif
