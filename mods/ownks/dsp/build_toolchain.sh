#!/bin/bash
# Builds the tic6x-elf binutils 2.42 + gcc 13.2.0 (C only, freestanding) used for mods/ownks/dsp.
# Sources: ftp.gnu.org (binutils-2.42.tar.xz sha256 f6e4d41f..., gcc-13.2.0.tar.xz sha256 e275e764...).
# Set T to a work dir; ownks.py finds the tools via CDJ_TIC6X (default work/ownks/tc/inst/bin).
set -e
T=work/ownks/tc; P=$T/inst; cd $T/src
[ -d binutils-2.42 ] || tar xf binutils-2.42.tar.xz
[ -d gcc-13.2.0 ] || tar xf gcc-13.2.0.tar.xz
mkdir -p b-bin && cd b-bin
../binutils-2.42/configure --target=tic6x-elf --prefix=$P --disable-nls --disable-werror --disable-gdb --disable-sim MAKEINFO=true > cfg.log 2>&1
make -j24 MAKEINFO=true > make.log 2>&1 && make install MAKEINFO=true > inst.log 2>&1
echo BINUTILS_OK
cd $T/src/gcc-13.2.0 && ./contrib/download_prerequisites > $T/src/prereq.log 2>&1
mkdir -p $T/src/b-gcc && cd $T/src/b-gcc
PATH=$P/bin:$PATH ../gcc-13.2.0/configure --target=tic6x-elf --prefix=$P --enable-languages=c --without-headers --with-newlib --disable-nls --disable-libssp --disable-libquadmath --disable-shared --disable-threads --disable-multilib MAKEINFO=true > cfg.log 2>&1
PATH=$P/bin:$PATH make -j24 all-gcc MAKEINFO=true > make.log 2>&1 && PATH=$P/bin:$PATH make install-gcc MAKEINFO=true > inst.log 2>&1
echo GCC_OK
PATH=$P/bin:$PATH make -j24 all-target-libgcc MAKEINFO=true > make-libgcc.log 2>&1 && PATH=$P/bin:$PATH make install-target-libgcc MAKEINFO=true >> inst.log 2>&1 && echo LIBGCC_OK || echo LIBGCC_FAIL
