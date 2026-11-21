#pragma once
#include <string>
#include <utility>
#include <vector>

/// Runs `argv` with extra environment variables; returns (exit code, stdout). -1 if it cannot start.
std::pair<int, std::string> runProcess(const std::vector<std::string>& argv,
                                       const std::vector<std::pair<std::string, std::string>>& env);
