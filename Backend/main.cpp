#include <signal.h>
#include <sys/types.h>
#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>
#include <unistd.h>

struct Process { int pid; std::string name; std::string cpu; std::string memory; std::string state; };

static std::string escapeJSON(const std::string& value) {
    std::string out;
    for (char c : value) { if (c == '"' || c == '\\') out += '\\'; out += c; }
    return out;
}

static std::vector<Process> listProcesses() {
    std::vector<Process> processes;
    FILE* pipe = popen("ps -axo pid=,pcpu=,pmem=,stat=,comm= | sort -rk2 | head -n 120", "r");
    if (!pipe) return processes;
    char buffer[2048];
    while (fgets(buffer, sizeof(buffer), pipe)) {
        std::istringstream row(buffer); Process p;
        if (!(row >> p.pid >> p.cpu >> p.memory >> p.state)) continue;
        std::getline(row, p.name);
        p.name.erase(p.name.begin(), std::find_if(p.name.begin(), p.name.end(), [](unsigned char c){ return !std::isspace(c); }));
        if (!p.name.empty()) processes.push_back(std::move(p));
    }
    pclose(pipe); return processes;
}

static bool terminateProcess(pid_t pid) {
    if (kill(pid, SIGTERM) != 0 && errno == ESRCH) {
        return true; // Já encerrado
    }
    usleep(50000); // 50ms
    if (kill(pid, 0) == 0) {
        kill(pid, SIGKILL);
        usleep(50000); // 50ms
    }
    return true;
}

int main(int argc, char* argv[]) {
    if (argc < 2) { std::cerr << "Uso: process-backend list|stop|start <pid>\n"; return 64; }
    std::string command = argv[1];
    if (command == "list") {
        auto items = listProcesses(); std::cout << "[";
        for (size_t i = 0; i < items.size(); ++i) { const auto& p = items[i];
            if (i) std::cout << ',';
            std::cout << "{\"pid\":" << p.pid << ",\"name\":\"" << escapeJSON(p.name)
                      << "\",\"cpu\":\"" << p.cpu << "\",\"memory\":\"" << p.memory
                      << "\",\"state\":\"" << escapeJSON(p.state) << "\"}";
        }
        std::cout << "]\n"; return 0;
    }
    if ((command == "stop" || command == "kill" || command == "start") && argc == 3) {
        char* end = nullptr; long raw = std::strtol(argv[2], &end, 10);
        if (*end || raw < 2 || raw > INT32_MAX) { std::cerr << "PID inválido\n"; return 64; }
        pid_t pid = static_cast<pid_t>(raw);
        if (command == "start") {
            int result = kill(pid, SIGCONT);
            if (result != 0) { std::cerr << std::strerror(errno) << '\n'; return 1; }
            return 0;
        } else {
            terminateProcess(pid);
            return 0;
        }
    }
    std::cerr << "Comando inválido\n"; return 64;
}
