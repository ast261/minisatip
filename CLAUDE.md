# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Minisatip is a multi-threaded SAT>IP v1.2 server written in C++. It bridges Linux DVB hardware to SAT>IP clients (Tvheadend, DVBViewer, etc.) over a network. The active branch (`idl4k-v2`) focuses on the **Inverto IDL4k / AXE platform** — a set-top-box hardware with 4 DVB-S2 tuners that uses a custom kernel driver instead of the standard Linux DVB API.

## Build Commands

```bash
cmake -S . -B build -DCMAKE_TOOLCHAIN_FILE=toolchain-idl4k.cmake -DAXE=ON -DDVBCSA=ON -DNETCVCLIENT=OFF   # configure for AXE target
cmake --build build                   # build minisatip binary
cmake --build build -- VERBOSE=1      # show compiler commands
cmake -S . -B build -DDEBUG=ON        # build with AddressSanitizer/UBSan
cmake -S . -B build -DBUILD_TESTING=ON && cmake --build build && ctest --test-dir build
```

Key cmake options (all default OFF unless a library is found):

| Option | Effect |
|--------|--------|
| `-DAXE=ON` | AXE (Inverto IDL4k) platform support |
| `-DDVBCSA=ON` | DVB-CSA descrambling (needs libdvbcsa) |
| `-DDVBCA=ON` | DVB-CA / CI support (needs libcrypto) |
| `-DDDCI=ON` | Dedicated CI; auto-enabled when DVBCA=ON on Linux |
| `-DNETCVCLIENT=ON` | NetCeiver client (needs libnetceiver, libxml2) |
| `-DLINUXDVB=OFF` | Disable Linux DVB API (default ON) |
| `-DSRT=ON` | SRT streaming support (needs libsrt) |
| `-DCXX23=ON` | C++23 stacktrace (needs libstdc++exp) |
| `-DSTATIC=ON` | Static linking |
| `-DDEBUG=ON` | AddressSanitizer / LeakSanitizer / UBSan |

## Running Tests

Tests are built and run via cmake:

```bash
cmake -S . -B build -DBUILD_TESTING=ON
cmake --build build
ctest --test-dir build
```

To compile and run a single test file manually:

```bash
cd build && g++ -Wall -ggdb -DTESTING -I../src -fsanitize=address \
    ../tests/test_adapter.cpp $(find ../src -name '*.cpp') -o /tmp/t \
    -lpthread -lrt -lcrypto -ldl && /tmp/t
```

## AXE Subsystem (`src/axe.cpp`, `src/axe.h`)

The AXE platform replaces the standard Linux DVB device tree with its own device nodes and ioctls. Everything below is specific to this hardware and does not apply to generic DVB adapters.

### Device Nodes

| Node | Purpose |
|------|---------|
| `/dev/axe/frontend-N` | Frontend tuning (opened with `O_RDONLY\|O_NONBLOCK` for detection, `O_RDWR` for use) |
| `/dev/axe/demuxts-N` | PID filtering and TS streaming (stored in `ad->dvr`) |
| `/dev/axe/fp-0` | Front-panel LED control (write text commands like `"T1_LED 1\n"`) |

`N` is the physical adapter index (`ad->pa`, 0–3). Standard `/dev/dvb/adapter*/` nodes are not used on AXE.

### Custom ioctls (`src/axe.h`)

**Frontend ioctls** (on `/dev/axe/frontend-N`):

| ioctl | Magic | Purpose |
|-------|-------|---------|
| `FE_FRONTEND_STANDBY` | `_IOW('o',91)` | Put frontend to standby |
| `FE_FRONTEND_RESET` | `_IO('o',93)` | Reset frontend (arg `0x54`) |
| `FE_FRONTEND_STATUS` | `_IOR('o',96)` | Read `fe_frontend_status_t` (packed struct: modulation, frequency, symbol_rate, fec, rolloff) |
| `FE_FRONTEND_INPUT` | `_IOW('o',97)` | Select physical input (0–3) before tuning |

**Demux/TS ioctls** (on `/dev/axe/demuxts-N`):

| ioctl | Magic | Purpose |
|-------|-------|---------|
| `DMXTS_ADD_PID` | `_IOW('o',1)` | Add PID to filter |
| `DMXTS_REMOVE_PID` | `_IOW('o',2)` | Remove PID from filter |
| `DMXTS_TRANSFER_START` | `_IO('o',5)` | Start plain TS transfer |
| `DMXTS_TRANSFER_START_RTP` | `_IOW('o',6)` | Start RTP transfer (passes `dmx_stream_params_t` with src/dst IP:port, SSRC) |
| `DMXTS_TRANSFER_STOP` | `_IO('o',7)` | Stop transfer |
| `DMXTS_RTP_SETUP_SSRC` | `_IOW('o',8)` | Set RTP SSRC |
| `DMXTS_TRANSFER_PAUSE/RESUME` | `_IO('o',9/10)` | Pause/resume |
| `DMXTS_GET_RTP_STREAM_STATE` | `_IOR('o',11)` | Read `rtp_state_t` (ssrc, ts, spc, soc, seq) |

### Adapter Initialization (`find_axe_adapter`)

`find_axe_adapter()` probes `/dev/axe/frontend-0..3`, and for each that opens successfully, allocates an `adapter` and wires it with AXE-specific function pointers:

```
open → axe_open_device      tune → axe_tune
set_pid → axe_set_pid       del_filters → axe_del_filters
get_signal → axe_get_signal close → axe_close
wakeup → axe_wakeup         standby → free_axe_input
delsys → axe_delsys         post_init → axe_post_init
```

`axe_delsys()` always returns `SYS_DVBS2` and reports only `{SYS_DVBS, SYS_DVBS2}` — the hardware is satellite-only.

### Input Sharing and `axe_used`

The AXE box has 4 physical LNB inputs shared across virtual adapter slots. `adapter->axe_used` is a **bitmask** where bit `N` means virtual adapter `N` is currently using this physical adapter's input. The function `axe_setup_switch()` contains the core sharing logic:

- Looks for an already-tuned physical adapter on the same transponder (same frequency + polarization + diseqc) to share.
- If found, increments `axe_used` and returns the already-tuned frequency (no re-tune needed).
- If not found, selects a free physical input, calls `axe_fe_input()` to switch it, then tunes.
- On close (`axe_close`), clears the bit in `axe_used` of the physical master adapter; puts it to standby if `axe_used == 0` and `sid_cnt == 0`.

`free_axe_input()` (used as `ad->standby`) clears the caller's bit from all physical adapter `axe_used` fields.

### Tuning Sequence (`axe_tune`)

1. `axe_set_tuner_led(aid+1, 1)` — light the LED
2. `axe_dmxts_stop(ad->dvr)` — stop any existing TS transfer
3. `axe_fe_reset(ad->fe)` — reset frontend
4. Drain stale data from `ad->dvr`
5. `FE_SET_PROPERTY(DTV_CLEAR)`
6. Build `dtv_property` array for the delivery system (DVB-S2 only on AXE)
7. `axe_pls_isi()` — apply MIS/PLS scrambling via I2C if needed (`axe_stv0900_i2c_4`)
8. `FE_SET_PROPERTY` with full property list including `DTV_TUNE`
9. `axe_dmxts_start(ad->dvr)` — start TS transfer

### Signal Quality (`axe_get_signal`)

Reads signal via `get_signal_old()` (the legacy DVB API ioctl path), then rescales:
- `strength`: raw value scaled to 0–240
- `snr`: scaled to 0–255, values ≤15 clamped to 0
- On lock loss with Unicable/JESS, automatically retries `axe_setup_switch()`

### Diagnostics (`axe_vdevice_sync`)

Reads `/proc/STAPI/stpti/PTI{aid}/vDeviceInfo` every 1 second to get packet count (`axe_pktc`) and continuity-counter errors (`axe_ccerr`). Exposed as `ad_axe_pktc`, `ad_axe_ccerr`, `ad_axe_coax` symbols in the web UI via `axe_sym[]`.

## General Architecture

**Data flow:** SAT>IP client → RTSP/HTTP → `socketworks` (poll loop) → `stream` (session) → `adapter` → AXE ioctls → TS packets → RTP/HTTP back to client.

- `src/adapter.cpp/.h` — manages up to 100 adapters; `struct_adapter` holds `fe`/`dvr` fds, `pa` (physical index), `axe_used` bitmask, LNB/diseqc config
- `src/stream.cpp/.h` — up to 256 client sessions; PID filtering per client; RTP sequencing
- `src/socketworks.cpp/.h` — poll-based multiplexer; all I/O via callback-driven `struct_sockets`
- `src/dvb.cpp/.h` — standard Linux DVB API path (not used on AXE hardware)
- `src/minisatip.cpp/.h` — main loop, RTSP state machine, SSDP, HTTP XML descriptor
- `src/opts.cpp/.h` — command-line option parsing; AXE-specific opts: `quattro`, `quattro_hiband`, `axe_power`
- `src/api/symbols.cpp/.h`, `src/api/variables.cpp/.h` — web UI symbol/variable registry
- `src/utils/` — alloc, fifo, hash_table, mutex, ticks, uuid
- `src/utils/dvb/` — DVB charset and SI table support (`dvb_support.cpp/.h`)

## Key Conventions

- `-DAXE` compile flag enables AXE support; emitted into `config.h` by cmake when `-DAXE=ON` is passed; `#ifdef AXE` blocks in `adapter.h` add `axe_used`, `axe_pktc`, `axe_ccerr`, `axe_vdevice_last_sync` fields to `struct_adapter`
- `TESTING` macro gates test-only code paths throughout `src/`
- Logging: module name `LOG_AXE` is the default in `axe.cpp`; pass `-l axe` at runtime for verbose, `-v axe` for debug
- Default ports: RTSP 554 (needs root), HTTP 8080, RTP base 5500
