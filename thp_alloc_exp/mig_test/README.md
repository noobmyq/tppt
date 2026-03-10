# Page Migration Test

The test creates a large region, places it on a source NUMA node by first touch, then repeatedly accesses only part of that region from another NUMA node so AutoNUMA can migrate the hot pages.

Important: `mmap()` does not decide final page placement. The pages are placed when they are first written. This test relies on:

1. Pinning the CPU to `--src-node`
2. Touching all pages once so they are allocated on that node
3. Pinning the CPU to `--dst-node`
4. Re-accessing only the hot subset to trigger migration

If the initial fill is done on the wrong CPU node, the pages may already be local and little or no migration will happen.

## Build

```bash
make pagetest
```

## Parameters

`--size-gb N`
- Total anonymous region size in GiB.
- Default: `50`

`--src-node N`
- NUMA node used during the initial full-region fill.
- This is where pages are intended to be allocated on first touch.
- Default: `1`

`--dst-node N`
- NUMA node used during the repeated access phase.
- This should usually be different from `--src-node`.
- Default: `0`

`--loop-pages P`
- Number of base pages to keep touching after initialization.
- Use this to define the hot working set directly in pages.

`--loop-gb G`
- Hot working set size in GiB.
- If both `--loop-gb` and `--loop-pages` are provided, the smaller result is used.

`--inner-step BYTES`
- Access stride inside each active page during the sweep.
- Default: `64`
- Must be between `1` and the system page size.

`--verify`
- Enables extra residency checks with `mincore()` and prints extra state.

## Example

```bash
./pagetest --size-gb 20 --src-node 1 --dst-node 0 --loop-gb 4 --inner-step 64 --verify
```

What this does:

1. Maps a 20 GiB anonymous region
2. Pins execution to node 1
3. Writes every page once so the region is allocated on node 1
4. Pins execution to node 0
5. Repeatedly sweeps only 4 GiB of the region
6. Lets AutoNUMA migrate the actively accessed pages toward node 0

## Notes

- `--src-node` and `--dst-node` should be different for a real remote-access case.
- AutoNUMA should be enabled:

```bash
cat /proc/sys/kernel/numa_balancing
```

Expected output:

```text
1
```

- `--loop-pages 262144` is about 1 GiB when the base page size is 4 KiB.
- one way to measure the migration number: 
sudo trace-cmd record   -e migrate:mm_migrate_pages   -e migrate:mm_migrate_pages_start   -F -c -- likwid-powermeter  /usr/bin/time -v ./xxx
