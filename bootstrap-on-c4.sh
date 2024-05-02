#! /bin/sh
# Test C4 bootstrap using the C4 virtual machine implemented in POSIX shell (c4.sh)

gcc -o c4 c4.c
./c4 -b -p c4.c > c4.op                             # Generate portable C4 bytecode for c4.c
ksh ./c4.sh --no-exit c4.op -b -p c4.c > c4-2.op    # Compile c4.c using c4.op with c4.sh VM
ksh ./c4.sh --no-exit c4-2.op -b -p c4.c > c4-3.op  # Bootstrap another time
diff c4-2.op c4-3.op                                # Compare bytecodes, should be empty
