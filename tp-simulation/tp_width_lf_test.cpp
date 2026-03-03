// test the load factor on different tp bit widths and different ops/cnt

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <iomanip>
#include <fstream>
#include <iostream>
#include <map>
#include <mutex>
#include <numeric>
#include <random>
#include <sstream>
#include <thread>
#include <utility>
#include <vector>
#include <xxhash.h>

uint64_t hash_func_1(uint64_t key) {
    static const uint64_t seed = 0x9e3779b97f4a7c15;
    return XXH64(&key, sizeof(key), seed);
}

uint64_t hash_func_2(uint64_t key) {
    static const uint64_t seed = 0x7f4a7c159e3779b9;
    return XXH64(&key, sizeof(key), seed);
}

struct BinHeader {
    uint16_t count;
    std::vector<char> free_slots;

    explicit BinHeader(uint16_t bin_size) : count(0), free_slots(bin_size, 1) {}
    BinHeader() = delete;

    int get_next_free_slot() {
        for (size_t i = 0; i < free_slots.size(); ++i) {
            if (free_slots[i]) {
                return static_cast<int>(i);
            }
        }
        return -1;
    }
};

struct DerefTab {
    uint16_t tp_bit_width;
    std::vector<BinHeader> bins;
    uint64_t total_slots;

    DerefTab() = delete;

    DerefTab(uint64_t max_slots, uint16_t bin_size, uint16_t tp_bit_width)
        : tp_bit_width(tp_bit_width), total_slots(0) {
        const uint64_t total_bins = max_slots / bin_size;
        total_slots = total_bins * bin_size;
        bins.resize(total_bins, BinHeader(bin_size));
    }

    std::pair<bool, uint16_t> insert(uint64_t key) {
        const uint64_t bin_idx1 = hash_func_1(key) % bins.size();
        const uint64_t bin_idx2 = hash_func_2(key) % bins.size();

        const bool use_hash_1 = bins[bin_idx1].count < bins[bin_idx2].count;
        const uint64_t chosen_bin_idx = use_hash_1 ? bin_idx1 : bin_idx2;
        BinHeader& chosen_bin = bins[chosen_bin_idx];

        const int free_slot_idx = chosen_bin.get_next_free_slot();
        if (free_slot_idx < 0) {
            return {false, 0};
        }

        chosen_bin.free_slots[free_slot_idx] = 0;
        ++chosen_bin.count;

        const uint16_t hash_bit = static_cast<uint16_t>(use_hash_1);
        const uint16_t slot_bits = static_cast<uint16_t>(free_slot_idx) &
            static_cast<uint16_t>((1ULL << (tp_bit_width - 1)) - 1);
        const uint16_t tinyptr =
            static_cast<uint16_t>((hash_bit << (tp_bit_width - 1)) | slot_bits);
        return {true, tinyptr};
    }

    bool remove(uint64_t key, uint16_t tinyptr) {
        const bool used_hash_1 = ((tinyptr >> (tp_bit_width - 1)) & 1U) != 0;
        const uint16_t slot_idx = tinyptr & static_cast<uint16_t>((1ULL << (tp_bit_width - 1)) - 1);

        const uint64_t bin_idx = used_hash_1 ? (hash_func_1(key) % bins.size())
                                             : (hash_func_2(key) % bins.size());
        BinHeader& bin = bins[bin_idx];

        if (slot_idx >= bin.free_slots.size() || bin.free_slots[slot_idx] == 1) {
            return false;
        }

        bin.free_slots[slot_idx] = 1;
        --bin.count;
        return true;
    }
};

// Return the maximum load factor that survives total_ops remove+insert churn.
double run_simulation(int bit_width, uint64_t max_tab_size, int ops_per_slot_exponent,
                      uint64_t run_salt,
                      std::atomic<uint64_t>* load_probe_counter,
                      std::atomic<uint64_t>* op_progress_counter) {
    const uint16_t bin_size = static_cast<uint16_t>((1ULL << (bit_width - 1)) - 1);
    DerefTab probe_tab(max_tab_size, bin_size, static_cast<uint16_t>(bit_width));

    const double ops_per_slot = std::pow(10.0, static_cast<double>(ops_per_slot_exponent));
    const uint64_t total_ops =
        static_cast<uint64_t>(std::llround(static_cast<double>(probe_tab.total_slots) * ops_per_slot));

    const uint64_t base_seed =
        (static_cast<uint64_t>(bit_width) << 32) ^
        static_cast<uint64_t>(ops_per_slot_exponent + 1000) ^
        (run_salt * 0x9e3779b97f4a7c15ULL);

    for (int load_milli = 995; load_milli >= 5; load_milli -= 5) {
        if (load_probe_counter != nullptr) {
            load_probe_counter->fetch_add(1, std::memory_order_relaxed);
        }
        const double target_load_factor = static_cast<double>(load_milli) / 1000.0;
        DerefTab deref_tab(max_tab_size, bin_size, static_cast<uint16_t>(bit_width));

        const uint64_t target_items =
            static_cast<uint64_t>(std::llround(static_cast<double>(deref_tab.total_slots) * target_load_factor));

        std::mt19937_64 rng(base_seed ^ static_cast<uint64_t>(load_milli));
        std::uniform_int_distribution<uint64_t> key_dist;

        std::vector<std::pair<uint64_t, uint16_t>> inserted_items;
        inserted_items.reserve(target_items);

        bool preload_ok = true;
        while (inserted_items.size() < target_items) {
            const uint64_t key = key_dist(rng);
            const auto [ok, tinyptr] = deref_tab.insert(key);
            if (!ok) {
                preload_ok = false;
                break;
            }
            inserted_items.emplace_back(key, tinyptr);
        }

        if (!preload_ok) {
            continue;
        }

        bool survived = true;
        constexpr uint64_t kOpHeartbeatStride = 1ULL << 20;  // 1,048,576 ops.
        uint64_t op_processed = 0;
        for (uint64_t op = 0; op < total_ops; ++op) {
            if (inserted_items.empty()) {
                break;
            }
            ++op_processed;

            std::uniform_int_distribution<size_t> idx_dist(0, inserted_items.size() - 1);
            const size_t idx = idx_dist(rng);

            const auto [old_key, old_tinyptr] = inserted_items[idx];
            if (!deref_tab.remove(old_key, old_tinyptr)) {
                survived = false;
                break;
            }

            const uint64_t new_key = key_dist(rng);
            const auto [ok, new_tinyptr] = deref_tab.insert(new_key);
            if (!ok) {
                survived = false;
                break;
            }

            inserted_items[idx] = {new_key, new_tinyptr};

            if (op_progress_counter != nullptr &&
                (op_processed & (kOpHeartbeatStride - 1)) == 0) {
                op_progress_counter->fetch_add(kOpHeartbeatStride,
                                               std::memory_order_relaxed);
            }
        }

        if (op_progress_counter != nullptr) {
            op_progress_counter->fetch_add(op_processed & (kOpHeartbeatStride - 1),
                                           std::memory_order_relaxed);
        }

        if (survived) {
            return target_load_factor;
        }
    }

    return 0.0;
}

struct SimulationRow {
    int bit_width;
    int ops_per_slot_exponent;
    double ops_per_slot;
    uint64_t total_ops;
    int repeats;
    double max_load_factor_mean;
    double max_load_factor_stddev;
};

struct SimulationJob {
    int bit_width;
    int ops_per_slot_exponent;
    int repeat_idx;
};

struct SimulationRunResult {
    int bit_width;
    int ops_per_slot_exponent;
    double ops_per_slot;
    uint64_t total_ops;
    double max_load_factor;
};

int main() {
    const int min_bit_width = 5;
    const int max_bit_width = 11;

    std::vector<int> bit_widths(max_bit_width - min_bit_width + 1);
    std::iota(bit_widths.begin(), bit_widths.end(), min_bit_width);

    const int min_ops_per_slot_exponent = -7;
    const int max_ops_per_slot_exponent = 5;
    const int simulation_repeats = 5;
    std::vector<int> ops_per_slot_counts_exponents(
        max_ops_per_slot_exponent - min_ops_per_slot_exponent + 1);
    std::iota(ops_per_slot_counts_exponents.begin(), ops_per_slot_counts_exponents.end(),
              min_ops_per_slot_exponent);

    const uint64_t max_tab_size = 1ULL << 22;
    std::vector<SimulationJob> jobs;
    jobs.reserve(
        bit_widths.size() * ops_per_slot_counts_exponents.size() * simulation_repeats);
    for (int bit_width : bit_widths) {
        for (int exponent : ops_per_slot_counts_exponents) {
            for (int rep = 0; rep < simulation_repeats; ++rep) {
                jobs.push_back({bit_width, exponent, rep});
            }
        }
    }

    std::vector<SimulationRunResult> run_results(jobs.size());
    std::atomic<size_t> next_job_idx{0};
    std::atomic<size_t> completed_jobs{0};
    std::atomic<uint64_t> load_probes_done{0};
    std::atomic<uint64_t> ops_processed{0};
    std::atomic<bool> workers_done{false};
    const unsigned int hw_threads = std::max(1u, std::thread::hardware_concurrency());
    const size_t worker_count = std::min(static_cast<size_t>(hw_threads), jobs.size());
    const size_t total_job_count = jobs.size();

    const std::string repeat_output_path = "output.csv";
    std::ofstream repeat_output_stream(
        repeat_output_path, std::ios::out | std::ios::trunc);
    if (!repeat_output_stream.is_open()) {
        std::cerr << "Failed to open " << repeat_output_path << " for writing."
                  << std::endl;
        return 1;
    }
    repeat_output_stream
        << "bit_width,ops_per_slot_exponent,repeat_idx,ops_per_slot,total_ops,max_load_factor"
        << std::endl;
    std::mutex repeat_output_mutex;

    auto format_duration = [](double seconds) -> std::string {
        const uint64_t total_secs = static_cast<uint64_t>(seconds);
        const uint64_t h = total_secs / 3600;
        const uint64_t m = (total_secs % 3600) / 60;
        const uint64_t s = total_secs % 60;
        std::ostringstream oss;
        oss << std::setfill('0') << std::setw(2) << h << ":"
            << std::setw(2) << m << ":" << std::setw(2) << s;
        return oss.str();
    };

    const auto progress_start = std::chrono::steady_clock::now();
    std::thread progress_reporter([&]() {
        while (!workers_done.load(std::memory_order_relaxed)) {
            std::this_thread::sleep_for(std::chrono::seconds(5));

            const auto now = std::chrono::steady_clock::now();
            const double elapsed_sec =
                std::chrono::duration<double>(now - progress_start).count();
            const size_t done = completed_jobs.load(std::memory_order_relaxed);
            const uint64_t probes =
                load_probes_done.load(std::memory_order_relaxed);
            const uint64_t ops = ops_processed.load(std::memory_order_relaxed);

            const double pct = total_job_count == 0
                                   ? 100.0
                                   : (100.0 * static_cast<double>(done) /
                                      static_cast<double>(total_job_count));
            const double jobs_per_sec =
                elapsed_sec > 0.0 ? static_cast<double>(done) / elapsed_sec : 0.0;
            const size_t remaining =
                done >= total_job_count ? 0 : (total_job_count - done);
            const double eta_sec =
                jobs_per_sec > 0.0 ? static_cast<double>(remaining) / jobs_per_sec
                                   : 0.0;

            std::cerr << "[progress] jobs=" << done << "/" << total_job_count
                      << " (" << std::fixed << std::setprecision(1) << pct
                      << "%), load_probes=" << probes
                      << ", churn_ops=" << ops
                      << ", elapsed=" << format_duration(elapsed_sec);
            if (jobs_per_sec > 0.0) {
                std::cerr << ", eta~" << format_duration(eta_sec);
            }
            std::cerr << std::defaultfloat << std::endl;
        }
    });

    std::vector<std::thread> workers;
    workers.reserve(worker_count);
    for (size_t worker = 0; worker < worker_count; ++worker) {
        workers.emplace_back([&jobs, &run_results, &next_job_idx, &completed_jobs,
                              &load_probes_done, &ops_processed,
                              &repeat_output_stream, &repeat_output_mutex,
                              max_tab_size]() {
            while (true) {
                const size_t idx = next_job_idx.fetch_add(1);
                if (idx >= jobs.size()) {
                    break;
                }

                const SimulationJob& job = jobs[idx];
                const uint16_t bin_size =
                    static_cast<uint16_t>((1ULL << (job.bit_width - 1)) - 1);
                const uint64_t total_bins = max_tab_size / bin_size;
                const uint64_t total_slots = total_bins * bin_size;
                const double ops_per_slot =
                    std::pow(10.0, static_cast<double>(job.ops_per_slot_exponent));
                const uint64_t total_ops = static_cast<uint64_t>(
                    std::llround(static_cast<double>(total_slots) * ops_per_slot));
                const double max_load_factor =
                    run_simulation(job.bit_width, max_tab_size, job.ops_per_slot_exponent,
                                   static_cast<uint64_t>(job.repeat_idx + 1),
                                   &load_probes_done, &ops_processed);

                run_results[idx] = {job.bit_width, job.ops_per_slot_exponent, ops_per_slot,
                                    total_ops, max_load_factor};

                std::ostringstream line;
                line << job.bit_width << ","
                     << job.ops_per_slot_exponent << ","
                     << (job.repeat_idx + 1) << ","
                     << std::scientific << std::setprecision(6) << ops_per_slot << ","
                     << std::defaultfloat << total_ops << ","
                     << std::fixed << std::setprecision(3) << max_load_factor
                     << std::defaultfloat << "\n";
                {
                    std::lock_guard<std::mutex> lock(repeat_output_mutex);
                    repeat_output_stream << line.str();
                    repeat_output_stream.flush();
                }

                completed_jobs.fetch_add(1, std::memory_order_relaxed);
            }
        });
    }

    for (auto& worker : workers) {
        worker.join();
    }
    workers_done.store(true, std::memory_order_relaxed);
    progress_reporter.join();

    struct AggregationState {
        int bit_width;
        int ops_per_slot_exponent;
        double ops_per_slot;
        uint64_t total_ops;
        int count;
        double sum;
        double sum_sq;
    };

    std::map<std::pair<int, int>, AggregationState> aggregate_by_key;
    for (const auto& r : run_results) {
        const std::pair<int, int> key = {r.bit_width, r.ops_per_slot_exponent};
        auto it = aggregate_by_key.find(key);
        if (it == aggregate_by_key.end()) {
            aggregate_by_key.emplace(
                key, AggregationState{r.bit_width, r.ops_per_slot_exponent, r.ops_per_slot,
                                      r.total_ops, 1, r.max_load_factor,
                                      r.max_load_factor * r.max_load_factor});
        } else {
            it->second.count += 1;
            it->second.sum += r.max_load_factor;
            it->second.sum_sq += r.max_load_factor * r.max_load_factor;
        }
    }

    std::vector<SimulationRow> all_rows;
    all_rows.reserve(bit_widths.size() * ops_per_slot_counts_exponents.size());
    for (const auto& [key, agg] : aggregate_by_key) {
        (void)key;
        const double mean = agg.sum / static_cast<double>(agg.count);
        const double variance =
            std::max(0.0, (agg.sum_sq / static_cast<double>(agg.count)) - (mean * mean));
        const double stddev = std::sqrt(variance);
        all_rows.push_back({agg.bit_width, agg.ops_per_slot_exponent, agg.ops_per_slot,
                            agg.total_ops, agg.count, mean, stddev});
    }

    std::sort(all_rows.begin(), all_rows.end(), [](const SimulationRow& a, const SimulationRow& b) {
        if (a.bit_width != b.bit_width) {
            return a.bit_width < b.bit_width;
        }
        return a.ops_per_slot_exponent < b.ops_per_slot_exponent;
    });

    std::cout << "bit_width,ops_per_slot_exponent,ops_per_slot,total_ops,repeats,max_load_factor,max_load_factor_stddev" << std::endl;

    for (const auto& row : all_rows) {
        std::cout << row.bit_width << ","
                  << row.ops_per_slot_exponent << ","
                  << std::scientific << std::setprecision(6) << row.ops_per_slot << ","
                  << std::defaultfloat << row.total_ops << ","
                  << row.repeats << ","
                  << std::fixed << std::setprecision(3) << row.max_load_factor_mean << ","
                  << std::fixed << std::setprecision(4) << row.max_load_factor_stddev << std::defaultfloat
                  << std::endl;
    }

    return 0;
}
