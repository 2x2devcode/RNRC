# RNRC — Rock N Rain Coin

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

RNRC (Rock N Rain Coin) is a decentralized, Proof-of-Stake cryptocurrency
derived from the Peercoin / NovaCoin codebase. It uses a hybrid PoW/PoS
consensus model: a small PoW phase bootstrapped the initial coin supply,
and Proof-of-Stake minting secures the network from that point forward.

---

## Table of Contents

1. [Coin Specifications](#coin-specifications)
2. [Proof of Stake — How It Works](#proof-of-stake--how-it-works)
3. [Network & Peers](#network--peers)
4. [Building from Source](#building-from-source)
   - [Linux (Ubuntu)](#linux-ubuntu)
   - [Windows (cross-compile from Ubuntu)](#windows-cross-compile-from-ubuntu)
   - [macOS](#macos)
5. [Running RNRC](#running-rnrc)
6. [Development](#development)
7. [License](#license)

---

## Coin Specifications

| Parameter | Value |
|---|---|
| Ticker | **RNRC** |
| Algorithm | Proof of Stake (PoS) |
| Block time | **2 minutes** |
| Annual PoS reward | **200 %** per year (on coin age spent) |
| Decimal places | 4 (1 RNRC = 10 000 base units) |
| Maximum supply | 92 000 000 000 RNRC (protocol hard cap) |
| PoW initial supply | blocks 1–10 → 4 000 000 000 RNRC per block (genesis bootstrap) |
| PoW reward (post-10) | 1 RNRC per block |
| Coinbase maturity | 6 blocks |
| Stake min age | **12 hours** |
| Stake max age | **30 days** (coins older than this do not accumulate further weight) |
| Modifier interval | 10 minutes |
| Retarget timespan | 15 minutes |
| P2P port (mainnet) | **18355** |
| RPC port (mainnet) | **18354** |
| P2P port (testnet) | 19555 |
| Protocol version | 60013 |
| Client version | 1.0.1 |
| Genesis hash | `000052c6cfc6ce3c5ef33f71b0848808a1a41d8602af94ec9ad58e8685f69eca` |

---

## Proof of Stake — How It Works

RNRC uses the **Peercoin-style Proof-of-Stake** mechanism.  Instead of
wasting electricity solving PoW puzzles, any wallet holding RNRC can
"stake" — sign new blocks and earn rewards proportional to **coin age**.

### Coin Age

Coin age is the product of the amount of RNRC held multiplied by the time
those coins have been idle in a confirmed output:

```
coin-age = amount × days_unspent
```

A UTXO starts accumulating coin age after **12 hours** (the minimum stake
age) and stops at **30 days** (the maximum).

### Staking Reward

The annual reward rate is **200 %** of the coin age spent each time a stake
block is found:

```
reward ≈ coin_age × (200 / 365) RNRC per day
```

The exact calculation in the codebase:

```cpp
// src/main.cpp
nSubsidy = nCoinAge * 33 / (365 * 33 + 8) * (200 * CENT); // 200% Forever
```

### How to Stake

1. **Keep your wallet open and unlocked for staking.**
   - GUI: `Settings → Unlock Wallet → check "For staking only"`.
   - CLI: `RNRCd walletpassphrase "your-passphrase" 9999999 true`.
2. **Ensure your coins are at least 12 hours old** in the receiving address.
3. **Maintain an internet connection** so your node can receive new blocks and
   broadcast your stake.
4. The wallet will automatically create stake transactions when a valid kernel
   hash is found.  You will see a new transaction of type `stake` in the history.

### Staking Tips

- Splitting a large balance into multiple UTXOs increases the chances of finding
  a valid kernel hash sooner.
- Consolidating very small outputs reduces wallet size and speeds up coin-age
  calculation.
- Run with `-rescan` after a long offline period to rebuild coin-age data.
- Use `-reservebalance=<amount>` to keep a portion of your balance exempt from
  staking.

---

## Network & Peers

**Block Explorer:** <http://149.102.139.53:30301/>

Add the following peers to your `RNRC.conf` (place it in the data directory):

```ini
addnode=149.102.139.53:18355
addnode=185.249.199.205:18355
addnode=121.142.85.242:18355
addnode=82.37.112.143:18355
```

The data directory is:

| OS | Default path |
|---|---|
| Linux | `~/.RNRC/` |
| Windows | `%APPDATA%\RNRC\` |
| macOS | `~/Library/Application Support/RNRC/` |

On first launch of **RNRC-Qt** (or if the previously saved data folder is missing), a welcome screen lets you choose the data directory. You can also point to a downloaded `bootstrap.dat` (or a folder containing it, or a `.gz` / `.zip`). The wallet copies or decompresses it into the data directory and imports the chain automatically on startup.

---

## Building from Source

### Prerequisites (all platforms)

- Git
- C++17-capable compiler
- Boost ≥ 1.71
- OpenSSL 3.x (static recommended)
- Berkeley DB 4.8
- Qt 5.x (GUI only)
- miniupnpc (optional)

---

### Linux (Ubuntu)

Tested on Ubuntu 22.04, 24.04 and 26.04.

#### 1 — Install dependencies

```bash
sudo apt update
sudo apt install -y \
    build-essential libssl-dev libboost-all-dev \
    libdb++-dev libminiupnpc-dev pkg-config git autoconf
```

For the Qt GUI wallet also install:

```bash
sudo apt install -y \
    qtbase5-dev qttools5-dev-tools libqt5gui5 libqt5network5 libqrencode-dev
```

#### 2 — Clone and build the CLI daemon

```bash
git clone https://github.com/2x2devcode/RNRC.git
cd RNRC/src
make -f makefile.unix -j$(nproc)
# Output: src/RNRCd
```

#### 3 — Build the Qt GUI wallet

```bash
cd ..          # repository root
qmake RNRC-qt.pro
make -j$(nproc)
# Output: RNRC-qt
```

#### 4 — First run

```bash
./src/RNRCd -daemon
# or GUI:
./RNRC-qt
```

---

### Windows (cross-compile from Ubuntu)

The repository ships an automated cross-compile script that builds both
`RNRCd.exe` and `RNRC-qt.exe` on Ubuntu 22.04 / 24.04 using
`x86_64-w64-mingw32`.

#### Quick start

```bash
git clone https://github.com/2x2devcode/RNRC.git
cd RNRC
./compile-windows.sh
# Outputs: release/windows/RNRCd.exe
#          release/windows/RNRC-qt.exe
```

The script will:

1. Install required host packages (mingw-w64, Qt, build tools).
2. Attempt to use MXE pre-built Qt packages; fall back to building
   `qtbase-5.15.2` from source (applying GCC 11 compatibility patches
   automatically).
3. Download and statically link OpenSSL, Berkeley DB 4.8, Boost 1.82,
   zlib, and miniupnpc under `depends/x86_64-w64-mingw32/`.
4. Produce fully self-contained executables — no MinGW DLLs required
   on the target Windows machine.

#### Optional environment variables

```bash
BUILD_GUI=0         # CLI only (skips Qt)
JOBS=8              # parallel make jobs
DEPS_DIR=/tmp/deps  # custom dependency prefix
QT_USE_OPENSSL=1    # link OpenSSL into Qt (default: Schannel)
```

#### Build logs

All output is saved under `release/windows/logs/`:

```
compile-windows-latest.log        # full output
compile-windows-latest.errors.txt # extracted errors only
cli-latest.log                     # CLI make stage
gui-latest.log                     # GUI make stage
qt-latest.log                      # Qt configure/make (if built from source)
```

#### Manual step-by-step

See [`doc/build-windows.txt`](doc/build-windows.txt) for a complete
manual cross-compile walkthrough.

---

### macOS

Tested on macOS 10.15 (Catalina) and later with Homebrew.
Build **on a Mac** (Xcode CLT + Homebrew). Cross-compile from Ubuntu is not supported.

#### Automatic build (recommended)

```bash
git clone https://github.com/2x2devcode/RNRC.git
cd RNRC
./compile-macos.sh
```

Outputs:

- `release/macos/RNRCd` — CLI daemon
- `release/macos/RNRC-Qt.app` — Qt GUI wallet (frameworks bundled via `macdeployqt`)

Useful options:

```bash
BUILD_CLI=0 ./compile-macos.sh          # GUI only
USE_UPNP=1 ./compile-macos.sh           # enable miniupnpc
MACOSX_DEPLOYMENT_TARGET=11.0 ./compile-macos.sh
```

No Apple Developer account is required to build or run locally. Notarized
public distribution needs the Apple Developer Program. See `doc/build-macos.txt`.

#### Manual build (Homebrew)

```bash
brew install boost openssl@3 berkeley-db@4 miniupnpc qt@5 pkg-config
```

CLI:

```bash
cd src
make -f makefile.osx -j$(sysctl -n hw.logicalcpu) RELEASE=1 USE_UPNP=- \
  OPENSSL_INCLUDE_PATH=$(brew --prefix openssl@3)/include \
  OPENSSL_LIB_PATH=$(brew --prefix openssl@3)/lib \
  BOOST_INCLUDE_PATH=$(brew --prefix boost)/include \
  BOOST_LIB_PATH=$(brew --prefix boost)/lib \
  BOOST_LIB_SUFFIX= \
  BDB_INCLUDE_PATH=$(brew --prefix berkeley-db@4)/include \
  BDB_LIB_PATH=$(brew --prefix berkeley-db@4)/lib \
  BDB_LIB_SUFFIX=-4.8
```

GUI:

```bash
cd ..   # repository root
export PATH="$(brew --prefix qt@5)/bin:$PATH"
qmake RELEASE=1 USE_UPNP=- \
  BOOST_INCLUDE_PATH=$(brew --prefix boost)/include \
  BOOST_LIB_PATH=$(brew --prefix boost)/lib \
  BOOST_LIB_SUFFIX= \
  BDB_INCLUDE_PATH=$(brew --prefix berkeley-db@4)/include \
  BDB_LIB_PATH=$(brew --prefix berkeley-db@4)/lib \
  BDB_LIB_SUFFIX=-4.8 \
  OPENSSL_INCLUDE_PATH=$(brew --prefix openssl@3)/include \
  OPENSSL_LIB_PATH=$(brew --prefix openssl@3)/lib \
  RNRC-qt.pro
make -j$(sysctl -n hw.logicalcpu)
# Output: RNRC-Qt.app
```

#### Notes

- On Apple Silicon, Homebrew under `/opt/homebrew` is used automatically.
- `compile-macos.sh` detects Boost/BDB library name suffixes for your brew install.
- If Berkeley DB 4.8 is not available in Homebrew, install from source with
  `--enable-cxx`.

---

## Running RNRC

### CLI daemon

```bash
# Start in background
./RNRCd -daemon

# Useful commands
./RNRCd getinfo
./RNRCd getstakinginfo
./RNRCd getblockcount
./RNRCd walletpassphrase "passphrase" 9999999 true  # unlock for staking

# Stop
./RNRCd stop
```

### Configuration file (`RNRC.conf`)

Place in the data directory (see table above):

```ini
# Network
addnode=149.102.139.53:18355
addnode=185.249.199.205:18355
addnode=82.37.112.143:18355

# RPC (optional — for local tools)
server=1
rpcuser=yourusername
rpcpassword=yourpassword
rpcallowip=127.0.0.1

# Staking
staking=1
# reservebalance=1000   # keep 1000 RNRC out of staking pool

# Resource / disk (optional)
# maxblkfilesize=209715200   # rotate blkNNNN.dat at ~200 MiB (default)
# maxconnections=40          # peer limit (default 40)
# minersleep=2000            # ms between stake attempts (default 2000; higher = less CPU)
# dbcache=16                 # LevelDB cache MiB (default 25; only a small part of RAM use)
# staking=0                  # lowest CPU if you are not staking
```

Most RAM use (~hundreds of MB to ~1 GB on a long chain) comes from the in-memory block index and wallet, not from `dbcache`. An existing huge `blk0001.dat` is not rewritten; after upgrading, new blocks are written to smaller `blk0002.dat`, `blk0003.dat`, … files.

---

## Development

### Branch workflow

- `master` — stable, always builds.
- `cursor/<feature>` — feature / fix branches.

### Coding style

See [`doc/coding.txt`](doc/coding.txt).

### Running tests

```bash
cd src
make -f makefile.unix test_RNRC
./test_RNRC
```

---

## License

RNRC is released under the [MIT License](LICENSE).

Copyright (c) 2009–2012 Bitcoin Developers  
Copyright (c) 2011–2013 NovaCoin Developers  
Copyright (c) 2012–2013 PPCoin Developers  
Copyright (c) 2019–present RNRC Developers
