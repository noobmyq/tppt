// TP vs vanilla 2-page-size fragmentation simulator.
// TP layout uses bit-width=8 => 127 rows per bin and huge stride=512 bins.

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <memory>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

constexpr uint64_t kTpBitWidth = 8;
constexpr uint64_t kBinSize = (1ULL << (kTpBitWidth - 1)) - 1;  // 127
constexpr uint64_t kHugeStride = 512;                            // 2MB / 4KB
constexpr uint64_t kFeasibleChunk = kBinSize * kHugeStride;      // 127 * 512
constexpr uint64_t kBasePageSize = 4096;
constexpr uint64_t kHugePageSize = 2ULL * 1024ULL * 1024ULL;
constexpr uint64_t kCheckpointBasePages = 512ULL * 512ULL;  // 1 GiB in base pages.
constexpr uint64_t kHeartbeatBasePages = 64ULL * 1024ULL;    // 256 MiB in base pages.

uint64_t splitmix64(uint64_t x) {
    x += 0x9e3779b97f4a7c15ULL;
    x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ULL;
    x = (x ^ (x >> 27)) * 0x94d049bb133111ebULL;
    return x ^ (x >> 31);
}

uint64_t hash_func_1(uint64_t key) {
    return splitmix64(key ^ 0x9e3779b97f4a7c15ULL);
}

uint64_t hash_func_2(uint64_t key) {
    return splitmix64(key ^ 0x7f4a7c159e3779b9ULL);
}

enum class AllocKind {
    Regular,
    Huge,
};

struct AllocationHandle {
    uint64_t id = 0;
    AllocKind kind = AllocKind::Regular;
    uint32_t row = 0;
    uint32_t col = 0;
    uint64_t base_page_index = 0;
};

struct LiveCounts {
    uint64_t regular = 0;
    uint64_t huge = 0;
};

struct AllocatorStats {
    uint64_t alloc_regular_ok = 0;
    uint64_t alloc_regular_fail = 0;
    uint64_t alloc_huge_ok = 0;
    uint64_t alloc_huge_fail = 0;
    uint64_t free_regular_ok = 0;
    uint64_t free_regular_fail = 0;
    uint64_t free_huge_ok = 0;
    uint64_t free_huge_fail = 0;
};

struct PoolGeometry {
    uint64_t requested_target_slots = 0;
    uint64_t feasible_slots = 0;
    uint64_t huge_bin_count = 0;
    uint64_t regular_bin_count = 0;
    uint64_t rows_per_bin = kBinSize;

    uint64_t total_rows() const {
        return huge_bin_count * rows_per_bin;
    }
};

PoolGeometry derive_geometry(uint64_t target_slots) {
    PoolGeometry g;
    g.requested_target_slots = target_slots;
    g.feasible_slots = (target_slots / kFeasibleChunk) * kFeasibleChunk;
    g.huge_bin_count = g.feasible_slots / kFeasibleChunk;
    g.regular_bin_count = g.huge_bin_count * kHugeStride;
    return g;
}

class IAllocatorModel {
public:
    virtual ~IAllocatorModel() = default;
    virtual const char* name() const = 0;
    virtual bool alloc_regular(uint64_t request_id, AllocationHandle* out) = 0;
    virtual bool alloc_huge(uint64_t request_id, AllocationHandle* out) = 0;
    virtual bool free_alloc(const AllocationHandle& handle) = 0;
    virtual bool materialize_huge_as_regular(const AllocationHandle& huge_handle,
                                             std::vector<AllocationHandle>* out_regular_pages) = 0;
    virtual double load_factor() const = 0;
    virtual uint64_t used_base_pages() const = 0;
    virtual uint64_t capacity_base_pages() const = 0;
    virtual uint64_t available_regular_slots() const = 0;
    virtual uint64_t available_huge_slots() const = 0;
    virtual LiveCounts live_counts() const = 0;
    virtual AllocatorStats stats() const = 0;
    virtual const PoolGeometry& geometry() const = 0;
};

class TpAllocatorModel : public IAllocatorModel {
public:
    explicit TpAllocatorModel(PoolGeometry geom) : geom_(std::move(geom)) {
        const uint64_t regular_slots_total = geom_.regular_bin_count * kBinSize;
        regular_slots_used_.assign(regular_slots_total, 0);
        regular_bin_load_.assign(geom_.regular_bin_count, 0);

        const uint64_t huge_rows_total = geom_.huge_bin_count * kBinSize;
        huge_row_occupied_.assign(huge_rows_total, 0);
        row_regular_occupancy_.assign(huge_rows_total, 0);
        huge_bin_load_.assign(geom_.huge_bin_count, 0);
    }

    const char* name() const override {
        return "tp";
    }

    bool alloc_regular(uint64_t request_id, AllocationHandle* out) override {
        if (geom_.regular_bin_count == 0) {
            ++stats_.alloc_regular_fail;
            return false;
        }
        const uint64_t bin_idx1 = hash_func_1(request_id) % geom_.regular_bin_count;
        const uint64_t bin_idx2 = hash_func_2(request_id) % geom_.regular_bin_count;

        const bool use_hash_1 = effective_bin_load(bin_idx1) < effective_bin_load(bin_idx2);
        const uint64_t chosen_bin = use_hash_1 ? bin_idx1 : bin_idx2;
        const uint64_t huge_bin_idx = chosen_bin / kHugeStride;
        const uint64_t local_bin = chosen_bin % kHugeStride;

        for (uint16_t row = 0; row < kBinSize; ++row) {
            const size_t row_slot = static_cast<size_t>(huge_bin_idx * kBinSize + row);
            if (huge_row_occupied_[row_slot]) {
                continue;
            }

            const size_t reg_off = regular_slot_offset(chosen_bin, row);
            if (regular_slots_used_[reg_off]) {
                continue;
            }

            regular_slots_used_[reg_off] = 1;
            ++regular_bin_load_[chosen_bin];
            ++row_regular_occupancy_[row_slot];
            ++used_base_pages_;
            ++live_regular_;
            ++stats_.alloc_regular_ok;

            if (out != nullptr) {
                out->id = request_id;
                out->kind = AllocKind::Regular;
                out->row = row;
                out->col = static_cast<uint32_t>(chosen_bin);
                out->base_page_index = physical_base_index(huge_bin_idx, local_bin, row);
            }
            return true;
        }

        ++stats_.alloc_regular_fail;
        return false;
    }

    bool alloc_huge(uint64_t request_id, AllocationHandle* out) override {
        if (geom_.huge_bin_count == 0) {
            ++stats_.alloc_huge_fail;
            return false;
        }
        const uint64_t huge_idx1 = hash_func_1(request_id) % geom_.huge_bin_count;
        const uint64_t huge_idx2 = hash_func_2(request_id) % geom_.huge_bin_count;

        const bool use_hash_1 = huge_bin_load_[huge_idx1] < huge_bin_load_[huge_idx2];
        const uint64_t chosen_huge = use_hash_1 ? huge_idx1 : huge_idx2;

        for (int row = static_cast<int>(kBinSize) - 1; row >= 0; --row) {
            const size_t row_slot = static_cast<size_t>(chosen_huge * kBinSize + row);
            if (huge_row_occupied_[row_slot]) {
                continue;
            }
            if (row_regular_occupancy_[row_slot] != 0) {
                continue;
            }

            huge_row_occupied_[row_slot] = 1;
            ++huge_bin_load_[chosen_huge];
            used_base_pages_ += kHugeStride;
            ++live_huge_;
            ++stats_.alloc_huge_ok;

            if (out != nullptr) {
                out->id = request_id;
                out->kind = AllocKind::Huge;
                out->row = static_cast<uint32_t>(row);
                out->col = static_cast<uint32_t>(chosen_huge);
                out->base_page_index = physical_base_index(chosen_huge, 0, static_cast<uint16_t>(row));
            }
            return true;
        }

        ++stats_.alloc_huge_fail;
        return false;
    }

    bool free_alloc(const AllocationHandle& handle) override {
        if (handle.kind == AllocKind::Regular) {
            return free_regular(handle);
        }
        return free_huge(handle);
    }

    bool materialize_huge_as_regular(const AllocationHandle& huge_handle,
                                     std::vector<AllocationHandle>* out_regular_pages) override {
        if (huge_handle.kind != AllocKind::Huge) {
            ++stats_.free_regular_fail;
            return false;
        }
        const uint64_t huge_bin = huge_handle.col;
        const uint16_t row = static_cast<uint16_t>(huge_handle.row);
        if (huge_bin >= geom_.huge_bin_count || row >= kBinSize) {
            ++stats_.free_regular_fail;
            return false;
        }

        const size_t row_slot = static_cast<size_t>(huge_bin * kBinSize + row);
        if (!huge_row_occupied_[row_slot] || row_regular_occupancy_[row_slot] != 0) {
            ++stats_.free_regular_fail;
            return false;
        }

        if (out_regular_pages != nullptr) {
            out_regular_pages->clear();
            out_regular_pages->reserve(kHugeStride);
        }

        huge_row_occupied_[row_slot] = 0;
        --huge_bin_load_[huge_bin];
        --live_huge_;

        for (uint16_t local_bin = 0; local_bin < kHugeStride; ++local_bin) {
            const uint64_t regular_bin = huge_bin * kHugeStride + local_bin;
            const size_t reg_off = regular_slot_offset(regular_bin, row);
            if (regular_slots_used_[reg_off]) {
                ++stats_.free_regular_fail;
                return false;
            }
            regular_slots_used_[reg_off] = 1;
            ++regular_bin_load_[regular_bin];

            if (out_regular_pages != nullptr) {
                out_regular_pages->push_back(AllocationHandle{
                    huge_handle.id,
                    AllocKind::Regular,
                    row,
                    static_cast<uint32_t>(regular_bin),
                    physical_base_index(huge_bin, local_bin, row),
                });
            }
        }

        row_regular_occupancy_[row_slot] = static_cast<uint16_t>(kHugeStride);
        live_regular_ += kHugeStride;
        return true;
    }

    double load_factor() const override {
        if (geom_.feasible_slots == 0) {
            return 0.0;
        }
        return static_cast<double>(used_base_pages_) / static_cast<double>(geom_.feasible_slots);
    }

    uint64_t used_base_pages() const override {
        return used_base_pages_;
    }

    uint64_t capacity_base_pages() const override {
        return geom_.feasible_slots;
    }

    uint64_t available_regular_slots() const override {
        return geom_.feasible_slots - used_base_pages_;
    }

    uint64_t available_huge_slots() const override {
        uint64_t free_rows = 0;
        for (size_t i = 0; i < huge_row_occupied_.size(); ++i) {
            if (!huge_row_occupied_[i] && row_regular_occupancy_[i] == 0) {
                ++free_rows;
            }
        }
        return free_rows;
    }

    LiveCounts live_counts() const override {
        return LiveCounts{live_regular_, live_huge_};
    }

    AllocatorStats stats() const override {
        return stats_;
    }

    const PoolGeometry& geometry() const override {
        return geom_;
    }

private:
    size_t regular_slot_offset(uint64_t regular_bin_idx, uint16_t row) const {
        return static_cast<size_t>(regular_bin_idx * kBinSize + row);
    }

    uint16_t effective_bin_load(uint64_t regular_bin_idx) const {
        const uint64_t huge_bin = regular_bin_idx / kHugeStride;
        const uint64_t blocked_rows = huge_bin_load_[huge_bin];
        return static_cast<uint16_t>(regular_bin_load_[regular_bin_idx] + blocked_rows);
    }

    uint64_t physical_base_index(uint64_t huge_bin_idx, uint64_t local_bin, uint16_t row) const {
        return huge_bin_idx * kFeasibleChunk + local_bin + static_cast<uint64_t>(row) * kHugeStride;
    }

    bool free_regular(const AllocationHandle& handle) {
        const uint64_t regular_bin = handle.col;
        const uint16_t row = static_cast<uint16_t>(handle.row);
        if (regular_bin >= geom_.regular_bin_count || row >= kBinSize) {
            ++stats_.free_regular_fail;
            return false;
        }

        const size_t reg_off = regular_slot_offset(regular_bin, row);
        if (!regular_slots_used_[reg_off]) {
            ++stats_.free_regular_fail;
            return false;
        }

        const uint64_t huge_bin_idx = regular_bin / kHugeStride;
        const size_t row_slot = static_cast<size_t>(huge_bin_idx * kBinSize + row);
        if (row_regular_occupancy_[row_slot] == 0) {
            ++stats_.free_regular_fail;
            return false;
        }

        regular_slots_used_[reg_off] = 0;
        --regular_bin_load_[regular_bin];
        --row_regular_occupancy_[row_slot];
        --used_base_pages_;
        --live_regular_;
        ++stats_.free_regular_ok;
        return true;
    }

    bool free_huge(const AllocationHandle& handle) {
        const uint64_t huge_bin = handle.col;
        const uint16_t row = static_cast<uint16_t>(handle.row);
        if (huge_bin >= geom_.huge_bin_count || row >= kBinSize) {
            ++stats_.free_huge_fail;
            return false;
        }

        const size_t row_slot = static_cast<size_t>(huge_bin * kBinSize + row);
        if (!huge_row_occupied_[row_slot]) {
            ++stats_.free_huge_fail;
            return false;
        }
        if (row_regular_occupancy_[row_slot] != 0) {
            ++stats_.free_huge_fail;
            return false;
        }

        huge_row_occupied_[row_slot] = 0;
        --huge_bin_load_[huge_bin];
        used_base_pages_ -= kHugeStride;
        --live_huge_;
        ++stats_.free_huge_ok;
        return true;
    }

    PoolGeometry geom_;
    uint64_t used_base_pages_ = 0;
    uint64_t live_regular_ = 0;
    uint64_t live_huge_ = 0;

    std::vector<uint8_t> regular_slots_used_;
    std::vector<uint16_t> regular_bin_load_;
    std::vector<uint8_t> huge_row_occupied_;
    std::vector<uint16_t> row_regular_occupancy_;
    std::vector<uint16_t> huge_bin_load_;
    AllocatorStats stats_;
};

class VanillaAllocatorModel : public IAllocatorModel {
public:
    explicit VanillaAllocatorModel(PoolGeometry geom) : geom_(std::move(geom)) {
        const uint64_t row_count = geom_.total_rows();
        row_state_.assign(row_count, RowState::HugeFree);
        split_row_used_count_.assign(row_count, 0);
        split_regular_slots_.assign(static_cast<size_t>(geom_.feasible_slots), 0);
    }

    const char* name() const override {
        return "vanilla";
    }

    bool alloc_regular(uint64_t request_id, AllocationHandle* out) override {
        (void)request_id;
        const uint64_t row_count = geom_.total_rows();

        for (uint64_t row = 0; row < row_count; ++row) {
            if (row_state_[row] != RowState::Split) {
                continue;
            }
            if (split_row_used_count_[row] >= kHugeStride) {
                continue;
            }

            for (uint16_t col = 0; col < kHugeStride; ++col) {
                const size_t idx = split_slot_offset(row, col);
                if (split_regular_slots_[idx]) {
                    continue;
                }

                split_regular_slots_[idx] = 1;
                ++split_row_used_count_[row];
                ++used_base_pages_;
                ++live_regular_;
                ++stats_.alloc_regular_ok;

                if (out != nullptr) {
                    out->id = request_id;
                    out->kind = AllocKind::Regular;
                    out->row = static_cast<uint32_t>(row);
                    out->col = col;
                    out->base_page_index = row * kHugeStride + col;
                }
                return true;
            }
        }

        for (uint64_t row = 0; row < row_count; ++row) {
            if (row_state_[row] != RowState::HugeFree) {
                continue;
            }

            row_state_[row] = RowState::Split;
            split_row_used_count_[row] = 1;
            split_regular_slots_[split_slot_offset(row, 0)] = 1;
            ++used_base_pages_;
            ++live_regular_;
            ++stats_.alloc_regular_ok;

            if (out != nullptr) {
                out->id = request_id;
                out->kind = AllocKind::Regular;
                out->row = static_cast<uint32_t>(row);
                out->col = 0;
                out->base_page_index = row * kHugeStride;
            }
            return true;
        }

        ++stats_.alloc_regular_fail;
        return false;
    }

    bool alloc_huge(uint64_t request_id, AllocationHandle* out) override {
        (void)request_id;
        const uint64_t row_count = geom_.total_rows();
        for (uint64_t row = 0; row < row_count; ++row) {
            if (row_state_[row] != RowState::HugeFree) {
                continue;
            }
            row_state_[row] = RowState::HugeAllocated;
            used_base_pages_ += kHugeStride;
            ++live_huge_;
            ++stats_.alloc_huge_ok;

            if (out != nullptr) {
                out->id = request_id;
                out->kind = AllocKind::Huge;
                out->row = static_cast<uint32_t>(row);
                out->col = 0;
                out->base_page_index = row * kHugeStride;
            }
            return true;
        }

        ++stats_.alloc_huge_fail;
        return false;
    }

    bool free_alloc(const AllocationHandle& handle) override {
        if (handle.kind == AllocKind::Regular) {
            return free_regular(handle);
        }
        return free_huge(handle);
    }

    bool materialize_huge_as_regular(const AllocationHandle& huge_handle,
                                     std::vector<AllocationHandle>* out_regular_pages) override {
        if (huge_handle.kind != AllocKind::Huge) {
            ++stats_.free_regular_fail;
            return false;
        }
        const uint64_t row = huge_handle.row;
        if (row >= geom_.total_rows()) {
            ++stats_.free_regular_fail;
            return false;
        }
        if (row_state_[row] != RowState::HugeAllocated) {
            ++stats_.free_regular_fail;
            return false;
        }

        if (out_regular_pages != nullptr) {
            out_regular_pages->clear();
            out_regular_pages->reserve(kHugeStride);
        }

        row_state_[row] = RowState::Split;
        split_row_used_count_[row] = static_cast<uint16_t>(kHugeStride);
        for (uint16_t col = 0; col < kHugeStride; ++col) {
            const size_t idx = split_slot_offset(row, col);
            split_regular_slots_[idx] = 1;
            if (out_regular_pages != nullptr) {
                out_regular_pages->push_back(AllocationHandle{
                    huge_handle.id,
                    AllocKind::Regular,
                    static_cast<uint32_t>(row),
                    col,
                    row * kHugeStride + col,
                });
            }
        }

        --live_huge_;
        live_regular_ += kHugeStride;
        return true;
    }

    double load_factor() const override {
        if (geom_.feasible_slots == 0) {
            return 0.0;
        }
        return static_cast<double>(used_base_pages_) / static_cast<double>(geom_.feasible_slots);
    }

    uint64_t used_base_pages() const override {
        return used_base_pages_;
    }

    uint64_t capacity_base_pages() const override {
        return geom_.feasible_slots;
    }

    uint64_t available_regular_slots() const override {
        return geom_.feasible_slots - used_base_pages_;
    }

    uint64_t available_huge_slots() const override {
        uint64_t free_rows = 0;
        for (const auto state : row_state_) {
            if (static_cast<uint8_t>(state) == 0) {
                ++free_rows;
            }
        }
        return free_rows;
    }

    LiveCounts live_counts() const override {
        return LiveCounts{live_regular_, live_huge_};
    }

    AllocatorStats stats() const override {
        return stats_;
    }

    const PoolGeometry& geometry() const override {
        return geom_;
    }

private:
    enum class RowState : uint8_t {
        HugeFree = 0,
        HugeAllocated = 1,
        Split = 2,
    };

    size_t split_slot_offset(uint64_t row, uint16_t col) const {
        return static_cast<size_t>(row * kHugeStride + col);
    }

    bool free_regular(const AllocationHandle& handle) {
        const uint64_t row = handle.row;
        const uint16_t col = static_cast<uint16_t>(handle.col);
        if (row >= geom_.total_rows() || col >= kHugeStride) {
            ++stats_.free_regular_fail;
            return false;
        }
        if (row_state_[row] != RowState::Split) {
            ++stats_.free_regular_fail;
            return false;
        }

        const size_t idx = split_slot_offset(row, col);
        if (!split_regular_slots_[idx] || split_row_used_count_[row] == 0) {
            ++stats_.free_regular_fail;
            return false;
        }

        split_regular_slots_[idx] = 0;
        --split_row_used_count_[row];
        --used_base_pages_;
        --live_regular_;
        ++stats_.free_regular_ok;

        if (split_row_used_count_[row] == 0) {
            row_state_[row] = RowState::HugeFree;
        }
        return true;
    }

    bool free_huge(const AllocationHandle& handle) {
        const uint64_t row = handle.row;
        if (row >= geom_.total_rows()) {
            ++stats_.free_huge_fail;
            return false;
        }
        if (row_state_[row] != RowState::HugeAllocated) {
            ++stats_.free_huge_fail;
            return false;
        }

        row_state_[row] = RowState::HugeFree;
        used_base_pages_ -= kHugeStride;
        --live_huge_;
        ++stats_.free_huge_ok;
        return true;
    }

    PoolGeometry geom_;
    uint64_t used_base_pages_ = 0;
    uint64_t live_regular_ = 0;
    uint64_t live_huge_ = 0;

    std::vector<RowState> row_state_;
    std::vector<uint16_t> split_row_used_count_;
    std::vector<uint8_t> split_regular_slots_;
    AllocatorStats stats_;
};

struct CheckpointRow {
    std::string allocator;
    std::string workload;
    std::string request_mix;
    int cycle = 0;
    std::string phase;
    uint64_t checkpoint_idx = 0;
    uint64_t pages_moved_in_phase = 0;
    uint64_t used_base_pages = 0;
    uint64_t available_slots_total = 0;
    uint64_t available_huge_slots = 0;
    double load_factor = 0.0;
};

struct CycleMetrics {
    int cycle = 0;
    double fill_target = 0.0;
    double fill_achieved = 0.0;
    double drain_target = 0.0;
    double drain_achieved = 0.0;

    uint64_t alloc_regular_ok = 0;
    uint64_t alloc_regular_fail = 0;
    uint64_t alloc_huge_ok = 0;
    uint64_t alloc_huge_fail = 0;
    uint64_t free_regular_ok = 0;
    uint64_t free_regular_fail = 0;
    uint64_t free_huge_ok = 0;
    uint64_t free_huge_fail = 0;

    uint64_t live_regular_end = 0;
    uint64_t live_huge_end = 0;
    uint64_t used_base_pages_end = 0;
    uint64_t total_base_pages = 0;
};

struct WorkloadConfig {
    double target_load = 0.0;
    double drain_load = 0.0;
    int cycles = 0;
    std::string request_mix = "mixed";
    double huge_prob = 0.5;
    uint64_t seed = 1;
};

class IWorkload {
public:
    explicit IWorkload(WorkloadConfig cfg)
        : cfg_(cfg), rng_(cfg.seed), next_request_id_(1) {}
    virtual ~IWorkload() = default;

    virtual const char* name() const = 0;
    virtual CycleMetrics run_cycle(int cycle_idx, IAllocatorModel& allocator, std::vector<CheckpointRow>* checkpoint_rows, const std::string& allocator_name) = 0;

protected:
    uint64_t next_request_id() {
        return next_request_id_++;
    }

    uint64_t target_fill_pages(const IAllocatorModel& allocator) const {
        const double raw =
            cfg_.target_load * static_cast<double>(allocator.capacity_base_pages());
        if (raw <= 0.0) {
            return 0;
        }
        return static_cast<uint64_t>(std::ceil(raw));
    }

    uint64_t target_drain_pages(const IAllocatorModel& allocator) const {
        const double raw =
            cfg_.drain_load * static_cast<double>(allocator.capacity_base_pages());
        if (raw <= 0.0) {
            return 0;
        }
        return static_cast<uint64_t>(std::floor(raw));
    }

    void note_progress_and_checkpoint(std::vector<CheckpointRow>* checkpoint_rows,
                                      const std::string& allocator_name,
                                      const char* phase,
                                      int cycle_idx,
                                      const IAllocatorModel& allocator,
                                      uint64_t delta_pages,
                                      uint64_t* moved_pages_in_phase,
                                      uint64_t* next_checkpoint_at) const {
        if (moved_pages_in_phase == nullptr || next_checkpoint_at == nullptr) {
            return;
        }
        *moved_pages_in_phase += delta_pages;
        if (checkpoint_rows == nullptr) {
            return;
        }
        while (*moved_pages_in_phase >= *next_checkpoint_at) {
            checkpoint_rows->push_back(CheckpointRow{
                allocator_name,
                name(),
                cfg_.request_mix,
                cycle_idx,
                phase,
                *next_checkpoint_at / kCheckpointBasePages,
                *next_checkpoint_at,
                allocator.used_base_pages(),
                allocator.available_regular_slots(),
                allocator.available_huge_slots(),
                allocator.load_factor(),
            });
            *next_checkpoint_at += kCheckpointBasePages;
        }
    }

    void emit_phase_heartbeat(const std::string& allocator_name,
                              int cycle_idx,
                              const char* phase,
                              uint64_t moved_pages_in_phase,
                              uint64_t phase_goal_pages,
                              const IAllocatorModel& allocator) const {
        std::ostringstream oss;
        oss << std::fixed << std::setprecision(3);
        oss << "[heartbeat] allocator=" << allocator_name
            << " workload=" << name()
            << " cycle=" << cycle_idx
            << " phase=" << phase
            << " moved_pages=" << moved_pages_in_phase;
        if (phase_goal_pages > 0) {
            const double pct = std::min(
                100.0,
                100.0 * static_cast<double>(moved_pages_in_phase) /
                    static_cast<double>(phase_goal_pages));
            oss << "/" << phase_goal_pages << " (" << pct << "%)";
        }
        oss << " used=" << allocator.used_base_pages() << "/" << allocator.capacity_base_pages()
            << " load=" << allocator.load_factor();
        std::cerr << oss.str() << "\n";
    }

    WorkloadConfig cfg_;
    std::mt19937_64 rng_;

private:
    uint64_t next_request_id_;
};

class SequentialWorkload : public IWorkload {
public:
    explicit SequentialWorkload(WorkloadConfig cfg)
        : IWorkload(cfg) {}

    const char* name() const override {
        return "sequential";
    }

    bool next_sequential_huge_request() {
        huge_request_credit_ += cfg_.huge_prob;
        if (huge_request_credit_ >= 1.0) {
            huge_request_credit_ -= 1.0;
            return true;
        }
        return false;
    }

    CycleMetrics run_cycle(int cycle_idx, IAllocatorModel& allocator, std::vector<CheckpointRow>* checkpoint_rows, const std::string& allocator_name) override {
        CycleMetrics m;
        m.cycle = cycle_idx;
        m.fill_target = cfg_.target_load;
        m.drain_target = cfg_.drain_load;
        m.total_base_pages = allocator.capacity_base_pages();

        uint64_t fill_pages_moved = 0;
        uint64_t next_fill_checkpoint = kCheckpointBasePages;
        uint64_t next_fill_heartbeat = kHeartbeatBasePages;
        const uint64_t fill_target_pages = target_fill_pages(allocator);
        const uint64_t fill_start_pages = allocator.used_base_pages();
        const uint64_t fill_goal_pages = (fill_target_pages > fill_start_pages)
                                             ? (fill_target_pages - fill_start_pages)
                                             : 0;
        emit_phase_heartbeat(allocator_name, cycle_idx, "fill-start", 0, fill_goal_pages,
                             allocator);
        while (allocator.used_base_pages() < fill_target_pages) {
            const bool allow_huge = (cfg_.request_mix == "mixed");
            const bool request_huge = allow_huge && next_sequential_huge_request();

            if (request_huge) {
                AllocationHandle huge_handle;
                if (allocator.alloc_huge(next_request_id(), &huge_handle)) {
                    std::vector<AllocationHandle> regular_pages;
                    if (!allocator.materialize_huge_as_regular(huge_handle, &regular_pages)) {
                        ++m.alloc_huge_fail;
                        break;
                    }
                    for (const auto& reg_page : regular_pages) {
                        live_regular_stack_.push_back(reg_page);
                    }
                    ++m.alloc_huge_ok;
                    note_progress_and_checkpoint(checkpoint_rows, allocator_name, "fill", cycle_idx,
                                                 allocator, kHugeStride, &fill_pages_moved,
                                                 &next_fill_checkpoint);
                } else {
                    ++m.alloc_huge_fail;
                    AllocationHandle reg_handle;
                    if (!allocator.alloc_regular(next_request_id(), &reg_handle)) {
                        ++m.alloc_regular_fail;
                        break;
                    }
                    live_regular_stack_.push_back(reg_handle);
                    ++m.alloc_regular_ok;
                    note_progress_and_checkpoint(checkpoint_rows, allocator_name, "fill", cycle_idx,
                                                 allocator, 1, &fill_pages_moved,
                                                 &next_fill_checkpoint);
                }
            } else {
                AllocationHandle reg_handle;
                if (!allocator.alloc_regular(next_request_id(), &reg_handle)) {
                    ++m.alloc_regular_fail;
                    break;
                }
                live_regular_stack_.push_back(reg_handle);
                ++m.alloc_regular_ok;
                note_progress_and_checkpoint(checkpoint_rows, allocator_name, "fill", cycle_idx,
                                             allocator, 1, &fill_pages_moved,
                                             &next_fill_checkpoint);
            }

            while (fill_pages_moved >= next_fill_heartbeat) {
                emit_phase_heartbeat(allocator_name, cycle_idx, "fill", fill_pages_moved,
                                     fill_goal_pages, allocator);
                next_fill_heartbeat += kHeartbeatBasePages;
            }
        }
        m.fill_achieved = allocator.load_factor();
        emit_phase_heartbeat(allocator_name, cycle_idx, "fill-end", fill_pages_moved,
                             fill_goal_pages, allocator);

        const uint64_t drain_target_pages = target_drain_pages(allocator);
        uint64_t drain_pages_moved = 0;
        uint64_t next_drain_checkpoint = kCheckpointBasePages;
        uint64_t next_drain_heartbeat = kHeartbeatBasePages;
        const uint64_t drain_start_pages = allocator.used_base_pages();
        const uint64_t drain_goal_pages = (drain_start_pages > drain_target_pages)
                                              ? (drain_start_pages - drain_target_pages)
                                              : 0;
        emit_phase_heartbeat(allocator_name, cycle_idx, "drain-start", 0, drain_goal_pages,
                             allocator);
        while (allocator.used_base_pages() > drain_target_pages) {
            if (live_regular_stack_.empty()) {
                break;
            }
            const AllocationHandle handle = live_regular_stack_.back();
            live_regular_stack_.pop_back();
            if (!allocator.free_alloc(handle)) {
                ++m.free_regular_fail;
                break;
            }
            ++m.free_regular_ok;
            note_progress_and_checkpoint(checkpoint_rows, allocator_name, "drain", cycle_idx,
                                         allocator, 1, &drain_pages_moved,
                                         &next_drain_checkpoint);
            while (drain_pages_moved >= next_drain_heartbeat) {
                emit_phase_heartbeat(allocator_name, cycle_idx, "drain", drain_pages_moved,
                                     drain_goal_pages, allocator);
                next_drain_heartbeat += kHeartbeatBasePages;
            }
        }
        emit_phase_heartbeat(allocator_name, cycle_idx, "drain-end", drain_pages_moved,
                             drain_goal_pages, allocator);

        m.drain_achieved = allocator.load_factor();
        const LiveCounts live = allocator.live_counts();
        m.live_regular_end = live.regular;
        m.live_huge_end = live.huge;
        m.used_base_pages_end = allocator.used_base_pages();
        return m;
    }

private:
    double huge_request_credit_ = 0.0;
    std::vector<AllocationHandle> live_regular_stack_;
};

class RandomWorkload : public IWorkload {
public:
    explicit RandomWorkload(WorkloadConfig cfg)
        : IWorkload(cfg) {}

    const char* name() const override {
        return "random";
    }

    CycleMetrics run_cycle(int cycle_idx, IAllocatorModel& allocator, std::vector<CheckpointRow>* checkpoint_rows, const std::string& allocator_name) override {
        CycleMetrics m;
        m.cycle = cycle_idx;
        m.fill_target = cfg_.target_load;
        m.drain_target = cfg_.drain_load;
        m.total_base_pages = allocator.capacity_base_pages();

        const uint64_t fill_target_pages = target_fill_pages(allocator);
        std::uniform_real_distribution<double> prob01(0.0, 1.0);
        uint64_t fill_pages_moved = 0;
        uint64_t next_fill_checkpoint = kCheckpointBasePages;
        uint64_t next_fill_heartbeat = kHeartbeatBasePages;
        const uint64_t fill_start_pages = allocator.used_base_pages();
        const uint64_t fill_goal_pages = (fill_target_pages > fill_start_pages)
                                             ? (fill_target_pages - fill_start_pages)
                                             : 0;
        emit_phase_heartbeat(allocator_name, cycle_idx, "fill-start", 0, fill_goal_pages,
                             allocator);

        while (allocator.used_base_pages() < fill_target_pages) {
            const bool request_huge =
                (cfg_.request_mix == "mixed") && (prob01(rng_) < cfg_.huge_prob);
            AllocationHandle handle;
            if (request_huge) {
                if (allocator.alloc_huge(next_request_id(), &handle)) {
                    std::vector<AllocationHandle> regular_pages;
                    if (!allocator.materialize_huge_as_regular(handle, &regular_pages)) {
                        ++m.alloc_huge_fail;
                        break;
                    }
                    for (const auto& reg_page : regular_pages) {
                        live_allocs_.push_back(reg_page);
                    }
                    ++m.alloc_huge_ok;
                    note_progress_and_checkpoint(checkpoint_rows, allocator_name, "fill", cycle_idx,
                                                 allocator, kHugeStride, &fill_pages_moved,
                                                 &next_fill_checkpoint);
                    while (fill_pages_moved >= next_fill_heartbeat) {
                        emit_phase_heartbeat(allocator_name, cycle_idx, "fill", fill_pages_moved,
                                             fill_goal_pages, allocator);
                        next_fill_heartbeat += kHeartbeatBasePages;
                    }
                    continue;
                }
                ++m.alloc_huge_fail;
                if (allocator.alloc_regular(next_request_id(), &handle)) {
                    live_allocs_.push_back(handle);
                    ++m.alloc_regular_ok;
                    note_progress_and_checkpoint(checkpoint_rows, allocator_name, "fill", cycle_idx,
                                                 allocator, 1, &fill_pages_moved,
                                                 &next_fill_checkpoint);
                    while (fill_pages_moved >= next_fill_heartbeat) {
                        emit_phase_heartbeat(allocator_name, cycle_idx, "fill", fill_pages_moved,
                                             fill_goal_pages, allocator);
                        next_fill_heartbeat += kHeartbeatBasePages;
                    }
                    continue;
                }
                ++m.alloc_regular_fail;
                break;
            }

            if (allocator.alloc_regular(next_request_id(), &handle)) {
                live_allocs_.push_back(handle);
                ++m.alloc_regular_ok;
                note_progress_and_checkpoint(checkpoint_rows, allocator_name, "fill", cycle_idx,
                                             allocator, 1, &fill_pages_moved,
                                             &next_fill_checkpoint);
                while (fill_pages_moved >= next_fill_heartbeat) {
                    emit_phase_heartbeat(allocator_name, cycle_idx, "fill", fill_pages_moved,
                                         fill_goal_pages, allocator);
                    next_fill_heartbeat += kHeartbeatBasePages;
                }
                continue;
            }
            ++m.alloc_regular_fail;
            break;
        }
        m.fill_achieved = allocator.load_factor();
        emit_phase_heartbeat(allocator_name, cycle_idx, "fill-end", fill_pages_moved,
                             fill_goal_pages, allocator);

        const uint64_t drain_target_pages = target_drain_pages(allocator);
        uint64_t drain_pages_moved = 0;
        uint64_t next_drain_checkpoint = kCheckpointBasePages;
        uint64_t next_drain_heartbeat = kHeartbeatBasePages;
        const uint64_t drain_start_pages = allocator.used_base_pages();
        const uint64_t drain_goal_pages = (drain_start_pages > drain_target_pages)
                                              ? (drain_start_pages - drain_target_pages)
                                              : 0;
        emit_phase_heartbeat(allocator_name, cycle_idx, "drain-start", 0, drain_goal_pages,
                             allocator);
        while (allocator.used_base_pages() > drain_target_pages) {
            if (live_allocs_.empty()) {
                break;
            }
            std::uniform_int_distribution<size_t> idx_dist(0, live_allocs_.size() - 1);
            const size_t idx = idx_dist(rng_);
            const AllocationHandle handle = live_allocs_[idx];
            const bool ok = allocator.free_alloc(handle);
            if (!ok) {
                ++m.free_regular_fail;
                live_allocs_[idx] = live_allocs_.back();
                live_allocs_.pop_back();
                break;
            }

            ++m.free_regular_ok;
            note_progress_and_checkpoint(checkpoint_rows, allocator_name, "drain", cycle_idx,
                                         allocator, 1,
                                         &drain_pages_moved, &next_drain_checkpoint);
            live_allocs_[idx] = live_allocs_.back();
            live_allocs_.pop_back();
            while (drain_pages_moved >= next_drain_heartbeat) {
                emit_phase_heartbeat(allocator_name, cycle_idx, "drain", drain_pages_moved,
                                     drain_goal_pages, allocator);
                next_drain_heartbeat += kHeartbeatBasePages;
            }
        }
        emit_phase_heartbeat(allocator_name, cycle_idx, "drain-end", drain_pages_moved,
                             drain_goal_pages, allocator);

        m.drain_achieved = allocator.load_factor();
        const LiveCounts live = allocator.live_counts();
        m.live_regular_end = live.regular;
        m.live_huge_end = live.huge;
        m.used_base_pages_end = allocator.used_base_pages();
        return m;
    }

private:
    std::vector<AllocationHandle> live_allocs_;
};

struct CliOptions {
    double target_load = -1.0;
    double drain_load = -1.0;
    int cycles = 0;
    uint64_t target_slots = 0;
    std::string workload = "random";
    std::string request_mix = "mixed";
    std::string allocator = "both";
    double huge_prob = 0.5;
    uint64_t seed = 1;
    std::string output_csv = "tp_allocator_frag_output.csv";
    std::string checkpoint_csv = "tp_allocator_frag_checkpoints.csv";
};

bool starts_with_dash_dash(const std::string& s) {
    return s.size() >= 2 && s[0] == '-' && s[1] == '-';
}

double parse_double_or_throw(const std::string& key, const std::string& val) {
    try {
        size_t idx = 0;
        const double out = std::stod(val, &idx);
        if (idx != val.size()) {
            throw std::runtime_error("trailing characters");
        }
        return out;
    } catch (const std::exception& e) {
        std::ostringstream oss;
        oss << "Invalid value for --" << key << ": '" << val << "' (" << e.what() << ")";
        throw std::runtime_error(oss.str());
    }
}

uint64_t parse_u64_or_throw(const std::string& key, const std::string& val) {
    try {
        size_t idx = 0;
        const unsigned long long out = std::stoull(val, &idx, 10);
        if (idx != val.size()) {
            throw std::runtime_error("trailing characters");
        }
        return static_cast<uint64_t>(out);
    } catch (const std::exception& e) {
        std::ostringstream oss;
        oss << "Invalid value for --" << key << ": '" << val << "' (" << e.what() << ")";
        throw std::runtime_error(oss.str());
    }
}

int parse_int_or_throw(const std::string& key, const std::string& val) {
    try {
        size_t idx = 0;
        const int out = std::stoi(val, &idx, 10);
        if (idx != val.size()) {
            throw std::runtime_error("trailing characters");
        }
        return out;
    } catch (const std::exception& e) {
        std::ostringstream oss;
        oss << "Invalid value for --" << key << ": '" << val << "' (" << e.what() << ")";
        throw std::runtime_error(oss.str());
    }
}

CliOptions parse_cli(int argc, char** argv) {
    CliOptions opts;
    std::unordered_map<std::string, std::string> kv;

    for (int i = 1; i < argc; ++i) {
        std::string token = argv[i];
        if (token == "--help" || token == "-h") {
            throw std::runtime_error("HELP");
        }
        if (!starts_with_dash_dash(token)) {
            std::ostringstream oss;
            oss << "Unexpected argument: " << token;
            throw std::runtime_error(oss.str());
        }

        std::string key;
        std::string value;
        const size_t eq_pos = token.find('=');
        if (eq_pos != std::string::npos) {
            key = token.substr(2, eq_pos - 2);
            value = token.substr(eq_pos + 1);
        } else {
            key = token.substr(2);
            if (i + 1 >= argc) {
                std::ostringstream oss;
                oss << "Missing value for --" << key;
                throw std::runtime_error(oss.str());
            }
            value = argv[++i];
        }
        kv[key] = value;
    }

    if (kv.count("target_load")) {
        opts.target_load = parse_double_or_throw("target_load", kv["target_load"]);
    }
    if (kv.count("drain_load")) {
        opts.drain_load = parse_double_or_throw("drain_load", kv["drain_load"]);
    }
    if (kv.count("cycles")) {
        opts.cycles = parse_int_or_throw("cycles", kv["cycles"]);
    }
    if (kv.count("target_slots")) {
        opts.target_slots = parse_u64_or_throw("target_slots", kv["target_slots"]);
    }
    if (kv.count("workload")) {
        opts.workload = kv["workload"];
    }
    if (kv.count("request_mix")) {
        opts.request_mix = kv["request_mix"];
    }
    if (kv.count("page_mix")) {
        opts.request_mix = kv["page_mix"];
    }
    if (kv.count("allocator")) {
        opts.allocator = kv["allocator"];
    }
    if (kv.count("huge_prob")) {
        opts.huge_prob = parse_double_or_throw("huge_prob", kv["huge_prob"]);
    }
    if (kv.count("seed")) {
        opts.seed = parse_u64_or_throw("seed", kv["seed"]);
    }
    if (kv.count("output_csv")) {
        opts.output_csv = kv["output_csv"];
    }
    if (kv.count("checkpoint_csv")) {
        opts.checkpoint_csv = kv["checkpoint_csv"];
    }

    if (opts.target_load < 0.0 || opts.drain_load < 0.0 || opts.cycles <= 0 ||
        opts.target_slots == 0) {
        throw std::runtime_error(
            "Missing required args. Required: --target_load --drain_load --cycles --target_slots");
    }
    if (!(0.0 <= opts.drain_load && opts.drain_load <= opts.target_load &&
          opts.target_load <= 1.0)) {
        throw std::runtime_error("Expected 0 <= drain_load <= target_load <= 1");
    }
    if (!(0.0 <= opts.huge_prob && opts.huge_prob <= 1.0)) {
        throw std::runtime_error("Expected 0 <= huge_prob <= 1");
    }
    const bool request_mix_explicit = kv.count("request_mix") || kv.count("page_mix");
    if (opts.workload == "seq_regular") {
        opts.workload = "sequential";
        if (!request_mix_explicit) {
            opts.request_mix = "regular";
        }
    } else if (opts.workload == "mixed") {
        opts.workload = "random";
        if (!request_mix_explicit) {
            opts.request_mix = "mixed";
        }
    }

    if (opts.workload != "sequential" && opts.workload != "random") {
        throw std::runtime_error("Expected --workload in {sequential,random}");
    }
    if (opts.request_mix != "regular" && opts.request_mix != "mixed") {
        throw std::runtime_error("Expected --request_mix in {regular,mixed}");
    }
    if (opts.allocator != "tp" && opts.allocator != "vanilla" && opts.allocator != "both") {
        throw std::runtime_error("Expected --allocator in {tp,vanilla,both}");
    }
    return opts;
}

void print_usage(const char* prog) {
    std::cerr
        << "Usage:\n"
        << "  " << prog
        << " --target_load <0..1> --drain_load <0..1> --cycles <N> --target_slots <S>\n"
        << "      [--workload sequential|random] [--request_mix regular|mixed]\n"
        << "      [--allocator tp|vanilla|both]\n"
        << "      [--huge_prob <0..1>] [--seed <u64>] [--output_csv <path>]\n"
        << "      [--checkpoint_csv <path>]\n\n"
        << "Notes:\n"
        << "  - TP bit width is fixed to 8 (bin size 127).\n"
        << "  - target_slots is rounded down to nearest multiple of 127*512.\n"
        << "  - base page = 4KB, huge page = 2MB (512 base pages).\n"
        << "  - checkpoint interval = 512*512 base pages (1 GiB moved per phase).\n";
}

std::unique_ptr<IAllocatorModel> make_allocator(const std::string& which,
                                                const PoolGeometry& geom) {
    if (which == "tp") {
        return std::make_unique<TpAllocatorModel>(geom);
    }
    if (which == "vanilla") {
        return std::make_unique<VanillaAllocatorModel>(geom);
    }
    throw std::runtime_error("unknown allocator: " + which);
}

std::unique_ptr<IWorkload> make_workload(const std::string& which,
                                         const WorkloadConfig& cfg) {
    if (which == "sequential") {
        return std::make_unique<SequentialWorkload>(cfg);
    }
    if (which == "random") {
        return std::make_unique<RandomWorkload>(cfg);
    }
    throw std::runtime_error("unknown workload: " + which);
}

struct ResultRow {
    std::string allocator;
    std::string workload;
    std::string request_mix;
    int cycle = 0;
    uint64_t requested_target_slots = 0;
    uint64_t feasible_slots = 0;
    uint64_t huge_bin_count = 0;
    uint64_t regular_bin_count = 0;
    double huge_prob = 0.0;
    uint64_t seed = 0;

    double fill_target = 0.0;
    double fill_achieved = 0.0;
    double drain_target = 0.0;
    double drain_achieved = 0.0;

    uint64_t alloc_regular_ok = 0;
    uint64_t alloc_regular_fail = 0;
    uint64_t alloc_huge_ok = 0;
    uint64_t alloc_huge_fail = 0;
    uint64_t free_regular_ok = 0;
    uint64_t free_regular_fail = 0;
    uint64_t free_huge_ok = 0;
    uint64_t free_huge_fail = 0;

    uint64_t live_regular_end = 0;
    uint64_t live_huge_end = 0;
    uint64_t used_base_pages_end = 0;
    uint64_t total_base_pages = 0;
};

void write_csv(const std::string& path, const std::vector<ResultRow>& rows) {
    std::ofstream out(path, std::ios::out | std::ios::trunc);
    if (!out.is_open()) {
        throw std::runtime_error("Failed to open output CSV: " + path);
    }

    out << "allocator,workload,request_mix,cycle,requested_target_slots,feasible_slots,huge_bin_count,regular_bin_count,"
        << "huge_prob,seed,fill_target,fill_achieved,drain_target,drain_achieved,"
        << "alloc_regular_ok,alloc_regular_fail,alloc_huge_ok,alloc_huge_fail,"
        << "free_regular_ok,free_regular_fail,free_huge_ok,free_huge_fail,"
        << "live_regular_end,live_huge_end,used_base_pages_end,total_base_pages\n";

    out << std::fixed << std::setprecision(6);
    for (const auto& r : rows) {
        out << r.allocator << ","
            << r.workload << ","
            << r.request_mix << ","
            << r.cycle << ","
            << r.requested_target_slots << ","
            << r.feasible_slots << ","
            << r.huge_bin_count << ","
            << r.regular_bin_count << ","
            << r.huge_prob << ","
            << r.seed << ","
            << r.fill_target << ","
            << r.fill_achieved << ","
            << r.drain_target << ","
            << r.drain_achieved << ","
            << r.alloc_regular_ok << ","
            << r.alloc_regular_fail << ","
            << r.alloc_huge_ok << ","
            << r.alloc_huge_fail << ","
            << r.free_regular_ok << ","
            << r.free_regular_fail << ","
            << r.free_huge_ok << ","
            << r.free_huge_fail << ","
            << r.live_regular_end << ","
            << r.live_huge_end << ","
            << r.used_base_pages_end << ","
            << r.total_base_pages << "\n";
    }
}

void write_checkpoint_csv(const std::string& path, const std::vector<CheckpointRow>& rows) {
    std::ofstream out(path, std::ios::out | std::ios::trunc);
    if (!out.is_open()) {
        throw std::runtime_error("Failed to open checkpoint CSV: " + path);
    }

    out << "allocator,workload,request_mix,cycle,phase,checkpoint_idx,pages_moved_in_phase,used_base_pages,available_slots_total,available_huge_slots,load_factor\n";

    out << std::fixed << std::setprecision(6);
    for (const auto& r : rows) {
        out << r.allocator << ","
            << r.workload << ","
            << r.request_mix << ","
            << r.cycle << ","
            << r.phase << ","
            << r.checkpoint_idx << ","
            << r.pages_moved_in_phase << ","
            << r.used_base_pages << ","
            << r.available_slots_total << ","
            << r.available_huge_slots << ","
            << r.load_factor << "\n";
    }
}

void print_summary(const std::vector<ResultRow>& rows) {
    std::cout << "allocator cycle fill_ach drain_ach "
              << "alloc_ok(r/h) alloc_fail(r/h) free_ok(r/h) live_end(r/h)\n";
    for (const auto& r : rows) {
        std::cout << std::setw(8) << r.allocator << " "
                  << std::setw(5) << r.cycle << " "
                  << std::fixed << std::setprecision(3)
                  << std::setw(8) << r.fill_achieved << " "
                  << std::setw(9) << r.drain_achieved << " "
                  << std::setw(8) << (std::to_string(r.alloc_regular_ok) + "/" + std::to_string(r.alloc_huge_ok)) << " "
                  << std::setw(10) << (std::to_string(r.alloc_regular_fail) + "/" + std::to_string(r.alloc_huge_fail)) << " "
                  << std::setw(8) << (std::to_string(r.free_regular_ok) + "/" + std::to_string(r.free_huge_ok)) << " "
                  << (std::to_string(r.live_regular_end) + "/" + std::to_string(r.live_huge_end))
                  << "\n";
    }
}

std::vector<std::string> allocators_to_run(const std::string& allocator_arg) {
    if (allocator_arg == "tp") {
        return {"tp"};
    }
    if (allocator_arg == "vanilla") {
        return {"vanilla"};
    }
    return {"tp", "vanilla"};
}

}  // namespace

int main(int argc, char** argv) {
    try {
        const CliOptions opts = parse_cli(argc, argv);
        const PoolGeometry geom = derive_geometry(opts.target_slots);
        if (geom.feasible_slots == 0 || geom.huge_bin_count == 0) {
            throw std::runtime_error(
                "target_slots too small after rounding. Need at least 127*512 slots.");
        }

        std::cerr << "Running TP/vanilla fragmentation simulation\n"
                  << "  base_page=" << kBasePageSize << "B"
                  << ", huge_page=" << kHugePageSize << "B"
                  << ", huge_stride=" << kHugeStride
                  << ", bin_size=" << kBinSize << "\n"
                  << "  requested_target_slots=" << geom.requested_target_slots
                  << ", feasible_slots=" << geom.feasible_slots
                  << ", huge_bin_count=" << geom.huge_bin_count
                  << ", regular_bin_count=" << geom.regular_bin_count << "\n";

        WorkloadConfig cfg;
        cfg.target_load = opts.target_load;
        cfg.drain_load = opts.drain_load;
        cfg.cycles = opts.cycles;
        cfg.request_mix = opts.request_mix;
        cfg.huge_prob = opts.huge_prob;
        cfg.seed = opts.seed;

        std::vector<ResultRow> output_rows;
        std::vector<CheckpointRow> checkpoint_rows;
        const std::vector<std::string> allocators = allocators_to_run(opts.allocator);
        for (const std::string& allocator_name : allocators) {
            auto allocator = make_allocator(allocator_name, geom);
            auto workload = make_workload(opts.workload, cfg);

            for (int cycle = 1; cycle <= cfg.cycles; ++cycle) {
                const CycleMetrics m = workload->run_cycle(cycle, *allocator, &checkpoint_rows, allocator_name);
                output_rows.push_back(ResultRow{
                    allocator_name,
                    opts.workload,
                    opts.request_mix,
                    m.cycle,
                    geom.requested_target_slots,
                    geom.feasible_slots,
                    geom.huge_bin_count,
                    geom.regular_bin_count,
                    cfg.huge_prob,
                    cfg.seed,
                    m.fill_target,
                    m.fill_achieved,
                    m.drain_target,
                    m.drain_achieved,
                    m.alloc_regular_ok,
                    m.alloc_regular_fail,
                    m.alloc_huge_ok,
                    m.alloc_huge_fail,
                    m.free_regular_ok,
                    m.free_regular_fail,
                    m.free_huge_ok,
                    m.free_huge_fail,
                    m.live_regular_end,
                    m.live_huge_end,
                    m.used_base_pages_end,
                    m.total_base_pages,
                });
            }
        }

        write_csv(opts.output_csv, output_rows);
        write_checkpoint_csv(opts.checkpoint_csv, checkpoint_rows);
        print_summary(output_rows);
        std::cout << "Cycle CSV written to: " << opts.output_csv << "\n";
        std::cout << "Checkpoint CSV written to: " << opts.checkpoint_csv << "\n";
        return 0;
    } catch (const std::exception& e) {
        const std::string msg = e.what();
        if (msg == "HELP") {
            print_usage(argv[0]);
            return 0;
        }
        std::cerr << "Error: " << msg << "\n\n";
        print_usage(argv[0]);
        return 1;
    }
}
