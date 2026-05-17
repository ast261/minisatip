# DVB API vs AXE API Comparison

This table maps standard Linux DVB API operations to their AXE/IDL4k equivalents. Use it as a porting reference when adapting a SAT>IP application to the Inverto IDL4k platform.

## Device Nodes

| Purpose | Standard DVB | AXE |
|---------|--------------|-----|
| Frontend tuning | `/dev/dvb/adapterN/frontendM` | `/dev/axe/frontend-N` |
| Demux / PID filter | `/dev/dvb/adapterN/demuxM` | `/dev/axe/demuxts-N` |
| DVR / TS stream | `/dev/dvb/adapterN/dvrM` | same fd as demuxts |
| Front-panel LED | — | `/dev/axe/fp-0` (write text commands) |

`N` is the physical adapter index (0–3). The demuxts fd serves both PID filtering and TS readout; there is no separate DVR node.

## Adapter Lifecycle

| Operation | Standard DVB | AXE |
|-----------|--------------|-----|
| Probe / detect | `open(frontend, O_RDONLY\|O_NONBLOCK)` | `open("/dev/axe/frontend-N", O_RDONLY\|O_NONBLOCK)` |
| Open frontend | `open(frontend, O_RDWR\|O_NONBLOCK)` | `open("/dev/axe/frontend-N", O_RDWR\|O_NONBLOCK)` |
| Open demux | `open(demux, O_RDWR\|O_NONBLOCK)` | `open("/dev/axe/demuxts-N", O_RDONLY\|O_NONBLOCK)` |
| Set demux buffer size | `ioctl(dvr, DMX_SET_BUFFER_SIZE, size)` | — (not applicable) |
| Set demux source | `ioctl(demux, DMX_SET_SOURCE, src)` | — (not applicable) |
| Close | `close(demux)` | Stop TS transfer, reset frontend, issue standby, then close |

## Frontend Reset and Standby

| Operation | Standard DVB | AXE ioctl |
|-----------|--------------|-----------|
| Soft reset | `FE_SET_PROPERTY({DTV_CLEAR})` | `FE_FRONTEND_RESET` `_IO('o',93)` — pass arg `0x54` |
| Standby | `FE_SET_VOLTAGE(SEC_VOLTAGE_OFF)` | `FE_FRONTEND_STANDBY` `_IOW('o',91)` then `FE_SET_VOLTAGE(SEC_VOLTAGE_OFF)` |
| Select physical input | — (adapter index = input) | `FE_FRONTEND_INPUT` `_IOW('o',97)` — pass input index 0–3 |

`FE_FRONTEND_INPUT` must be called before tuning whenever the physical input needs switching. The IDL4k has four LNB inputs that can be shared across virtual adapter slots.

## Tuning

| Operation | Standard DVB | AXE |
|-----------|--------------|-----|
| Prepare for retune | `FE_SET_PROPERTY({DTV_CLEAR})` | Stop TS transfer + `FE_FRONTEND_RESET` + drain stale data + `FE_SET_PROPERTY({DTV_CLEAR})` |
| Set tuning properties | `FE_SET_PROPERTY` with `DTV_FREQUENCY`, `DTV_SYMBOL_RATE`, `DTV_INNER_FEC`, `DTV_PILOT`, `DTV_ROLLOFF`, `DTV_MODULATION`, `DTV_DELIVERY_SYSTEM`, `DTV_TUNE` | Same `FE_SET_PROPERTY` path; DVB-S2 only — `DTV_PILOT` and `DTV_ROLLOFF` are not used |
| Legacy fallback | `FE_SET_FRONTEND` | Not supported; use `FE_SET_PROPERTY` only |
| MIS/PLS scrambling | `DTV_STREAM_ID` / `DTV_SCRAMBLING_SEQUENCE_INDEX` property | Same properties, additionally programmed via I2C to the STV0900 demodulator |
| Start TS after tune | — (demux already open and running) | `DMXTS_TRANSFER_START` `_IO('o',5)` |

## PID Filtering

| Operation | Standard DVB | AXE |
|-----------|--------------|-----|
| Initialize demux | `ioctl(demux, DMX_SET_PES_FILTER, &params)` with `DMX_IMMEDIATE_START` | — (transfer already started at tune time) |
| Add PID | `ioctl(demux, DMX_ADD_PID, &pid)` | `DMXTS_ADD_PID` `_IOW('o',1)` |
| Remove PID | `ioctl(demux, DMX_REMOVE_PID, &pid)` | `DMXTS_REMOVE_PID` `_IOW('o',2)` |
| Stop filtering | `ioctl(demux, DMX_STOP)` | `DMXTS_TRANSFER_STOP` `_IO('o',7)` |

## RTP Streaming

On standard DVB hardware the application reads raw TS from the DVR fd and handles RTP packetization itself. On AXE this can be offloaded entirely to the kernel driver.

| Operation | Standard DVB | AXE |
|-----------|--------------|-----|
| RTP packetization | Done in application | Offloaded to kernel driver |
| Start RTP stream | — | `DMXTS_TRANSFER_START_RTP` `_IOW('o',6)` with `dmx_stream_params_t` (src/dst IP:port, SSRC) |
| Set / change SSRC | — | `DMXTS_RTP_SETUP_SSRC` `_IOW('o',8)` |
| Pause / resume | — | `DMXTS_TRANSFER_PAUSE` `_IO('o',9)` / `DMXTS_TRANSFER_RESUME` `_IO('o',10)` |
| Read RTP stats | — | `DMXTS_GET_RTP_STREAM_STATE` `_IOR('o',11)` → `rtp_state_t` (ssrc, ts, spc, soc, seq) |

## Signal Quality

| Operation | Standard DVB | AXE |
|-----------|--------------|-----|
| Lock status | `ioctl(fe, FE_READ_STATUS, &status)` | Same ioctl |
| Bit error rate | `ioctl(fe, FE_READ_BER, &ber)` | Same ioctl |
| Signal strength | `ioctl(fe, FE_READ_SIGNAL_STRENGTH, &strength)` | Same ioctl; raw value should be rescaled to 0–240 |
| SNR | `ioctl(fe, FE_READ_SNR, &snr)` | Same ioctl; rescale to 0–255, clamp values ≤15 to 0 |
| Extended status | `FE_GET_PROPERTY(DTV_STAT_*)` | `FE_FRONTEND_STATUS` `_IOR('o',96)` → `fe_frontend_status_t` (packed struct: modulation, frequency, symbol_rate, fec, rolloff) |

## Frontend Capabilities

| Operation | Standard DVB | AXE |
|-----------|--------------|-----|
| Query delivery systems | `FE_GET_PROPERTY(DTV_ENUM_DELSYS)` | Fixed: `{SYS_DVBS, SYS_DVBS2}` — no need to query |
| Query frontend info | `FE_GET_INFO` → `dvb_frontend_info` | Not required; hardware capabilities are fixed |

## DiSEqC / LNB Control

DiSEqC commands use the same standard DVB ioctls on both paths — `FE_DISEQC_SEND_MASTER_CMD`, `FE_DISEQC_SEND_BURST`, `FE_SET_TONE`, `FE_SET_VOLTAGE` — because the AXE frontend fd also exposes the DVB SEC interface.

The key difference is **input selection**: before issuing DiSEqC, call `FE_FRONTEND_INPUT` to assign the desired physical LNB input (0–3) to this frontend. On standard DVB, the physical input is implied by which adapter device was opened. On AXE, multiple virtual adapters can share a single physical input when they are tuned to the same transponder, so input assignment is explicit and must be coordinated across adapters.
