#pragma once

#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include "logos_module_context.h"

/**
 * Vesting module (RFP-017 prototype). Every method returns the JSON object printed by
 * `vesting --json ...`: {"ok":true,...} or {"ok":false,"error":"V0xx ..."}.
 * Keys never leave the wallet; the module never reads or returns key material.
 */
class VestingModuleImpl : public LogosModuleContext
{
public:
    /// Current settings: cli path, wallet home, program id, dev-mode flag (no secrets).
    std::string getConfig();
    /// Merge settings from a JSON object (keys: cli, wallet_home, program, dev_mode).
    std::string setConfig(const std::string& json);

    std::string accounts();
    std::string listSchedules();
    std::string show(const std::string& creator, const std::string& id);
    std::string track(const std::string& creator, const std::string& id);

    /// kind: "linear" (start,cliff,end in unix ms) or "milestones" (comma-separated amounts).
    std::string create(const std::string& creator, const std::string& beneficiary, const std::string& total,
                       const std::string& kind, const std::string& values, bool cancelable, bool transferable);
    /// Pre-claim summary: amount, fee estimate, fee payer balance, privacy disclosure. Sends nothing.
    std::string quoteClaim(const std::string& beneficiary, const std::string& creator, const std::string& id,
                           const std::string& privateAccount);
    /// privateAccount empty = public claim to the beneficiary.
    std::string claim(const std::string& beneficiary, const std::string& creator, const std::string& id,
                      const std::string& privateAccount);
    std::string receivePending();
    std::string cancel(const std::string& creator, const std::string& id);
    std::string signalMilestone(const std::string& creator, const std::string& id, int64_t index);
    /// One-way: a cancelable schedule becomes non-cancelable.
    std::string makeIrrevocable(const std::string& creator, const std::string& id);
    /// The beneficiary hands a transferable position to newBeneficiary.
    std::string transferBeneficiary(const std::string& beneficiary, const std::string& creator, const std::string& id,
                                    const std::string& newBeneficiary);
    /// Many schedules in one transaction. entriesJson: the `vesting create-batch` JSON array.
    std::string createBatch(const std::string& creator, const std::string& entriesJson);
    /// Sending methods (create, createBatch, claim, cancel, signalMilestone, makeIrrevocable,
    /// transferBeneficiary, receivePending) return
    /// {"ok":true,"pending":true,"job":"N"} at once, since proving and inclusion outlast a bridge
    /// call. Poll this until it returns the final object.
    std::string jobResult(const std::string& job);

private:
    std::map<std::string, std::string> settings();
    std::string configPath();
    std::string run(std::vector<std::string> args, bool isRead = true);
    std::string startJob(std::vector<std::string> args);

    std::timed_mutex m_cliLock;                 // one CLI at a time: each one rewrites the wallet storage
    std::mutex m_jobsLock;
    std::map<std::string, std::shared_ptr<std::string>> m_jobs;  // empty string = still running
    int64_t m_nextJob = 1;
};
