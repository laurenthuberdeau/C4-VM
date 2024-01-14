#!/bin/sh

# set -x # Prints all commands run
set -e # Exit on first error

debug=0       # Print debug information, mostly during initialization
trace=0       # Trace the execution of the VM
trace_stack=0 # Trace the stack when tracing instructions
trace_heap=1  # Trace the heap when tracing instructions
strict_mode=1 # Ensures that all variables are initialized before use
enable_strict_mode() {
  if [ $trace_stack -eq 0 ] && [ $strict_mode -eq 1 ] ; then
    set -u # Exit on using unset variable
  fi
}
enable_strict_mode

# Infinite loop breaker.
# On a M1 CPU, 35518 cycles take 18 seconds to run, so 100000 is a minute of execution.
MAX_CYCLE=100000

# Opcodes
LEA=0; IMM=1; REF=2; JMP=3; JSR=4; BZ=5; BNZ=6; ENT=7; ADJ=8; LEV=9; LI=10; LC=11; SI=12; SC=13; PSH=14; OR=15; XOR=16; AND=17; EQ=18; NE=19; LT=20; GT=21; LE=22; GE=23; SHL=24; SHR=25; ADD=26; SUB=27; MUL=28; DIV=29; MOD=30; OPEN=31; READ=32; CLOS=33; PRTF=34; MALC=35; FREE=36; MSET=37; MCMP=38; EXIT=39;

INITIAL_STACK_POS=1000000
INITIAL_HEAP_POS=0
sp=$INITIAL_STACK_POS
push_stack() {
  : $((sp--))
  : $((_data_$sp=$1))
}
pop_stack() {
  : $((res = _data_$sp))
  : $((sp++))
}
at_stack() {
  : $((res = _data_$(($1 + $sp))))
}

alloc_memory() {
  res=$dat
  : $((dat += $1))
  # Need to initialize the memory to 0 or else `set -u` will complain
  if [ $strict_mode -eq 1 ] ; then
    ix=$res
    while [ $ix -lt $dat ]; do
      : $((_data_$ix=0))
      : $((ix++))
    done
  fi
}

dat=$INITIAL_HEAP_POS
push_data() {
  : $((_data_$dat=$1))
  : $((dat++))
}
pop_data() {
  : $((dat--))
  : $((res = _data_$dat))
}

# Push a Shell string to the VM heap. Returns a reference to the string in $addr.
unpack_string() {
  addr=$dat
  src_buf="$1"
  while [ -n "$src_buf" ] ; do
    char="$src_buf"                    # remember current buffer
    rest="${src_buf#?}"                # remove the first char
    char="${char%"$rest"}"             # remove all but first char
    src_buf="${src_buf#?}"             # remove the current char from $src_buf
    code=$(LC_CTYPE=C printf "%d" "'$char'")
    push_data "$code"
  done
  push_data 0
}

# Convert a VM string reference to a Shell string. $res is set to the result.
pack_string() {
  addr="$1"
  res=""
  while [ "$((_data_$addr))" -ne 0 ] ; do
    char="$((_data_$addr))"
    addr=$((addr + 1))
    case $char in
      10) res="$res\n" ;; # 10 == '\n'
      *) res=$res$(printf "\\$(printf "%o" "$char")") # Decode
    esac
  done
}

src_buf=
get_char()                           # get next char from source into $char
{
  if [ -z "$src_buf" ] ; then        # need to get next line when buffer empty
    IFS=                             # don't split input
    if read -r src_buf ; then        # read next line into $src_buf
      if [ -z "$src_buf" ] ; then    # an empty line implies a newline character
        char=NEWLINE                 # next get_char call will read next line
        return
      fi
    else
      char=EOF                       # EOF reached when read fails
      return
    fi
  else
    src_buf="${src_buf#?}"           # remove the current char from $src_buf
    if [ -z "$src_buf" ] ; then      # end of line if the buffer is now empty
      char=NEWLINE
      return
    fi
  fi

  # current character is at the head of $src_buf

  char="$src_buf"                    # remember current buffer
  rest="${src_buf#?}"                # remove the first char
  char="${char%"$rest"}"             # remove all but first char
}

# Used to implement the read instruction.
# Does not work with NUL characters.
read_n_char() {
  count=$1
  buf_ptr=$2
  while [ "$count" != "0" ] ; do
    get_char
    case "$char" in
      EOF) break ;;
      NEWLINE) code=10 ;; # 10 == '\n'
      *) code=$(LC_CTYPE=C printf "%d" "'$char") # convert to integer code ;;
    esac

    : $((_data_$buf_ptr=$code))
    : $((count--))
    : $((buf_ptr++))
  done

  : $((_data_$buf_ptr=0))
}

# Same as get_char, but \ is recognized as the start of an escape sequence.
# If an escape sequence is found, $char is set its ascii code and $escaped is set to true.
# If the next character is not \, the function behaves just like get_char.
get_char_encoded() {
  get_char
  escaped="false"
  # If $char is \, then the next 2 characters are the hex code of the character
  if [ '\' = "$char" ] ; then
    escaped="true"
    get_char
    x1=$char
    get_char
    x2=$char
    : $((char=0x$x1$x2))
    return
  fi
}

parse_identifier()
{
  while : ; do
    case "$char" in
      [0-9a-zA-Z_])
        token="$token$char"
        get_char
        ;;
      *)
        break
        ;;
    esac
  done
}

get_token() {
  value=

  while : ; do
    token=$char
    get_char

    case "$token" in
      ' '|NEWLINE)                   # skip whitespace
          while : ; do
            case "$char" in
              ' ') get_char ;;
              NEWLINE) token=$char ; get_char ;;
              *) break ;;
            esac
          done
          ;;

      [0-9-])                         # parse integer
          value="$token"
          token=INTEGER
          while : ; do
            case "$char" in
              [0-9])
                value="$value$char"
                get_char
                ;;
              *)
                break
                ;;
            esac
          done
          break
          ;;

      [a-zA-Z_])                     # parse identifier or C keyword
          parse_identifier
          value="$token"
          token=IDENTIFIER
          break
          ;;

        *)                             # all else is treated as single char token
          break                        # (if there is no such token the parser
          ;;                           # will detect it and give an error)

    esac
  done
}

get_num() {
  get_token
  if [ "$token" != "INTEGER" ] ; then
    echo "Expected number, got $token: $value"; exit 1;
  fi
}

read_data() {
  get_char
  get_num
  count=$value

  if [ $debug -eq 1 ] ; then
    echo "Reading $value bytes of data"
  fi

  while [ "$count" != "0" ] ; do
    get_char_encoded
    if [ $escaped = "true" ] ; then
      code=$char
    else
    code=$(LC_CTYPE=C printf "%d" "'$char") # convert to integer code
    fi
    push_data $code
    : $((count--))
  done

  # Read final newline
  get_char
}

# Encode instructions to internal representation.
# To inspect instructions, use decode_instructions and print_instructions.
encode_instruction() {
  # This big case statement could be replaced with res=$(( $(($1)) )) but it
  # wouldn't handle the case where $1 is an invalid instruction, which is useful
  # for debugging.
  case "$1" in
    LEA)  res=$LEA ;;
    IMM)  res=$IMM ;;
    REF)  res=$REF ;;
    JMP)  res=$JMP ;;
    JSR)  res=$JSR ;;
    BZ)   res=$BZ ;;
    BNZ)  res=$BNZ ;;
    ENT)  res=$ENT ;;
    ADJ)  res=$ADJ ;;
    LEV)  res=$LEV ;;
    LI)   res=$LI ;;
    LC)   res=$LC ;;
    SI)   res=$SI ;;
    SC)   res=$SC ;;
    PSH)  res=$PSH ;;
    OR)   res=$OR ;;
    XOR)  res=$XOR ;;
    AND)  res=$AND ;;
    EQ)   res=$EQ ;;
    NE)   res=$NE ;;
    LT)   res=$LT ;;
    GT)   res=$GT ;;
    LE)   res=$LE ;;
    GE)   res=$GE ;;
    SHL)  res=$SHL ;;
    SHR)  res=$SHR ;;
    ADD)  res=$ADD ;;
    SUB)  res=$SUB ;;
    MUL)  res=$MUL ;;
    DIV)  res=$DIV ;;
    MOD)  res=$MOD ;;
    OPEN) res=$OPEN ;;
    READ) res=$READ ;;
    CLOS) res=$CLOS ;;
    PRTF) res=$PRTF ;;
    MALC) res=$MALC ;;
    FREE) res=$FREE ;;
    MSET) res=$MSET ;;
    MCMP) res=$MCMP ;;
    EXIT) res=$EXIT ;;
    *) echo "Unknown instruction $1" ; exit 1 ;;
  esac
}

# Without arrays it's hard to write this function in a way that isn't verbose.
decode_instruction() {
  case "$1" in
    $LEA)  res=LEA ;;
    $IMM)  res=IMM ;;
    $REF)  res=REF ;;
    $JMP)  res=JMP ;;
    $JSR)  res=JSR ;;
    $BZ)   res=BZ ;;
    $BNZ)  res=BNZ ;;
    $ENT)  res=ENT ;;
    $ADJ)  res=ADJ ;;
    $LEV)  res=LEV ;;
    $LI)   res=LI ;;
    $LC)   res=LC ;;
    $SI)   res=SI ;;
    $SC)   res=SC ;;
    $PSH)  res=PSH ;;
    $OR)   res=OR ;;
    $XOR)  res=XOR ;;
    $AND)  res=AND ;;
    $EQ)   res=EQ ;;
    $NE)   res=NE ;;
    $LT)   res=LT ;;
    $GT)   res=GT ;;
    $LE)   res=LE ;;
    $GE)   res=GE ;;
    $SHL)  res=SHL ;;
    $SHR)  res=SHR ;;
    $ADD)  res=ADD ;;
    $SUB)  res=SUB ;;
    $MUL)  res=MUL ;;
    $DIV)  res=DIV ;;
    $MOD)  res=MOD ;;
    $OPEN) res=OPEN ;;
    $READ) res=READ ;;
    $CLOS) res=CLOS ;;
    $PRTF) res=PRTF ;;
    $MALC) res=MALC ;;
    $FREE) res=FREE ;;
    $MSET) res=MSET ;;
    $MCMP) res=MCMP ;;
    $EXIT) res=EXIT ;;
    *) echo "Unknown instruction code $1" ; exit 1 ;;
  esac
}

# Read instructions and encode them until EOF.
read_instructions() {
  get_token
  count=0
  while : ; do
    case "$token" in
      EOF) break ;;
      INTEGER)
        if [ $patch_next_imm = "true" ] ; then
          value=$(($value + $patch))
        fi
        push_data $value ;;
      IDENTIFIER) encode_instruction $value ; push_data $res ;;
      *) echo "Unknown instruction $value" ; exit 1 ;;
    esac
    # Because instructions with relative addresses are relative to 0, we need to
    # patch them to be relative to the start of the instructions.
    case "$value" in
      "REF") patch_next_imm="true" ; patch=$1 ;;
      "JMP") patch_next_imm="true" ; patch=$2 ;;
      "JSR") patch_next_imm="true" ; patch=$2 ;;
      "BZ")  patch_next_imm="true" ; patch=$2 ;;
      "BNZ") patch_next_imm="true" ; patch=$2 ;;
      *)     patch_next_imm="false"; ;;
    esac
    : $((count++))
    get_token
  done
  if [ $debug -eq 1 ] ; then
    echo "Finished reading $count instructions"
  fi
}

# Useful for debugging
print_instructions() {
  echo "Main starts at position $main_addr"
  instr=$instr_start

  while [ $instr -lt $last_instr ]; do
    ix=$instr
    : $((i = _data_$instr))
    : $((instr++))

    if [ $i -le $ADJ ] ; then
      : $((imm = _data_$instr))
      : $((instr++))
      decode_instruction $i
      echo "$ix: $res  $imm"
    else
      decode_instruction $i
      echo "$ix: $res"
    fi
  done
}

run_instructions() {
  while : ; do
    : $((i = _data_$pc))
    : $((pc++))
    : $((cycle++))

    if [ $i -le $ADJ ] ; then
      : $((imm = _data_$pc))
      : $((pc++))
    fi

    if [ $trace -eq 1 ] ; then
      debug_str=""
      instr_str=""
      # Current instruction
      decode_instruction $i
      if [ $i -le $ADJ ] ; then
        instr_str="$debug_str $res  $imm"
      else
        instr_str="$debug_str $res"
      fi

      # VM registers
      debug_str="$cycle> \n    $instr_str\n    pc = $pc, sp = $sp, bp = $bp, hp = $dat, a = $a"
      # Stack
      # Because the stack may contain undefined values, this code is incompatible with the set -u option
      if [ $trace_stack -eq 1 ] ; then
        stack_ix=$INITIAL_STACK_POS
        debug_str="$debug_str\n    Stack:"
        while [ $stack_ix -gt $sp ]; do
          : $((stack_ix--))
          debug_str="$debug_str\n        _data_$stack_ix = $((_data_$stack_ix))"
        done
      fi

      # Heap
      if [ $trace_heap -eq 1 ] ; then
        heap_ix=$INITIAL_HEAP_POS
        debug_str="$debug_str\n    Heap:"
        echo "heap pointer: $dat"
        while [ $heap_ix -lt $dat ]; do
          ascii=$((_data_$heap_ix))
          char=""
          if [ $ascii -ge 31 ] && [ $ascii -le 127 ] ; then
            char=$(printf "\\$(printf "%o" "$ascii")")
          fi
          debug_str="$debug_str\n        _data_$heap_ix = $ascii  ($char)"
          : $((heap_ix++))
        done
      fi
      echo $debug_str
    fi

    # Infinite loop breaker
    if [ $cycle -gt $MAX_CYCLE ] ; then
      echo "Too many instructions, aborting execution."
      exit 1;
    fi

    case "$i" in
      "$LEA") a=$((bp + imm)) ;;                # a = (int)(bp + *pc++);
      "$IMM") a=$imm ;;                         # a = *pc++;
      "$REF") a=$imm ;;                         # a = *pc++;
      "$JMP") pc=$imm ;;                        # pc = (int *)*pc;
      "$JSR") push_stack $pc ; pc=$imm ;;       # { *--sp = (int)(pc + 1); pc = (int *)*pc; }
      "$BZ") [ $a -eq 0 ] && pc=$imm ;;         # pc = a ? pc + 1 : (int *)*pc;
      "$BNZ") [ $a - ne 0 ] && pc=$imm ;;       # pc = a ? (int *)*pc : pc + 1;
      "$ENT")                                   # { *--sp = (int)bp; bp = sp; sp = sp - *pc++; } // enter subroutine
        push_stack $bp
        bp=$sp
        sp=$((sp - imm))
        ;;
      "$ADJ") sp=$((sp + imm)) ;;               # sp += *pc++; // stack adjust
      "$LEV")                                   # { sp = bp; bp = (int *)*sp++; pc = (int *)*sp++; } // leave subroutine
        sp=$bp
        bp=$((_data_$sp))
        sp=$((sp + 1))
        pc=$((_data_$sp))
        sp=$((sp + 1))
        ;;
      "$LI") a=$((_data_$a)) ;;                 # a = *(int *)a;
      "$LC") a=$((_data_$a)) ;;                 # a = *(char *)a;
      "$SI") : $((_data_$((_data_$sp))=$a)) ;;  # *(int *)*sp++ = a;
      "$SC") : $((_data_$((_data_$sp))=$a)) ;;  # a = *(char *)*sp++ = a;
      "$PSH") push_stack "$a" ;;                # *--sp = a;
      "$OR")  pop_stack; a=$((res | a)) ;;
      "$XOR") pop_stack; a=$((res ^ a)) ;;
      "$AND") pop_stack; a=$((res & a)) ;;
      "$EQ")  pop_stack; a=$((res == a)) ;;
      "$NE")  pop_stack; a=$((res != a)) ;;
      "$LT")  pop_stack; a=$((res < a)) ;;
      "$GT")  pop_stack; a=$((res > a)) ;;
      "$LE")  pop_stack; a=$((res <= a)) ;;
      "$GE")  pop_stack; a=$((res >= a)) ;;
      "$SHL") pop_stack; a=$((res << a)) ;;
      "$SHR") pop_stack; a=$((res >> a)) ;;
      "$ADD") pop_stack; a=$((res + a)) ;;
      "$SUB") pop_stack; a=$((res - a)) ;;
      "$MUL") pop_stack; a=$((res * a)) ;;
      "$DIV") pop_stack; a=$((res / a)) ;;
      "$MOD") pop_stack; a=$((res % a)) ;;
      "$OPEN")                                  # a = open((char *)sp[1], *sp);
        # We represent file descriptors as strings. That means that modes and offsets do not work.
        # These limitations are acceptable since c4.cc does not use them.
        # TODO: Packing and unpacking the string is a lazy way of copying a string
        at_stack 1
        pack_string "$res"
        unpack_string "$res"
        a=$addr
        ;;
      "$READ")                                  # a = read(sp[2], (char *)sp[1], *sp);
        at_stack 2; fd=$res
        at_stack 1; buf=$res
        at_stack 0; count=$res
        pack_string "$fd"
        read_n_char $count $buf < "$res" # We don't want to use cat because it's not pure Shell
        ;;
      "$CLOS")                                  # a = close(*sp);
        # NOP
        ;;
      "$PRTF")                                  # { t = sp + pc[1]; a = printf((char *)t[-1], t[-2], t[-3], t[-4], t[-5], t[-6]); }
        # Disable strict mode because printf takes optional paramters and can read uninitialized values
        set +u
        # this part is weird. We look 2 bytes ahead to get the number of arguments.
        # This works because all PRTF instructions are followed by a ADJ with the number of arguments to printf as parameter.
        : $((count = _data_$((pc + 1))))

        at_stack $((count - 1)); fmt=$res
        at_stack $((count - 2)); arg1=$res
        at_stack $((count - 3)); arg2=$res
        at_stack $((count - 4)); arg3=$res
        at_stack $((count - 5)); arg4=$res
        at_stack $((count - 6)); arg5=$res

        pack_string "$fmt"
        # Not sure about how the arguments are interpolated here. If each arg is quoted, printf prints multiple strings.
        # If they are not quoted, printf prints a single string but I worry that spaces in the arguments will be
        # interpreted as multiple arguments. That doesn't seem to be the case though.
        printf "$res" "$arg1 $arg2 $arg3 $arg4 $arg5"
        enable_strict_mode # Reset the script mode
        ;;
      "$MALC")                                  # a = (int)malloc(*sp);
        # Simple bump allocator, no GC
        mem_to_alloc=$((_data_$sp))
        alloc_memory $mem_to_alloc
        a=$res
        ;;
      "$FREE")                                  # free((void *)*sp);
        # NOP
        # Maybe zero out the memory to make debugging easier?
        ;;
      "$MSET")                                  # a = (int)memset((char *)sp[2], sp[1], *sp);
        at_stack 2; dst=$res
        at_stack 1; val=$res
        at_stack 0; len=$res
        ix=0
        while [ $ix -lt $len ]; do
          : $((_data_$((dst + ix)) = val))
          : $((ix++))
        done
        ;;
      "$MCMP")                                  # a = memcmp((char *)sp[2], (char *)sp[1], *sp);
        at_stack 2; op1=$res
        at_stack 1; op2=$res
        at_stack 0; len=$res
        ix=0; a=0
        while [ $ix -lt $len ]; do
          if [ $((_data_$((op1 + ix)))) -ne $((_data_$((op2 + ix)))) ] ; then
            # From man page: returns the difference between the first two differing bytes (treated as unsigned char values
            : $((a = _data_$((op1 + ix)) - _data_$((op2 + ix))))
            break
          fi
        done
        ;;
      "$EXIT")                                  # { printf("exit(%d) cycle = %d\n", *sp, cycle); return *sp; }
        echo "exit($a) cycle = $cycle"
        exit "$a"
        ;;
      *)
        echo "unknown instruction = $i! cycle = $cycle"
        exit 1
        ;;
    esac
  done
}

run() {
  dat_start=$dat
  read_data
  instr_start=$dat
  get_num
  main_addr=$(($value + $instr_start))
  read_instructions $dat_start $instr_start
  last_instr=$dat
  if [ $debug -eq 1 ] ; then
    print_instructions
  fi

  # sp=0;
  pc=$main_addr; bp=$sp; a=0; cycle=0; # vm registers
  i=0; t=0 # temps

  # setup first stack frame
  push_stack $EXIT # call exit if main returns
  push_stack $PSH
  t=$sp
  argc=$#; push_stack $argc # argc
  alloc_memory $argc ; argv_ptr=$res ; push_stack $res # argv

  while [ $# -ge 1 ]; do
    unpack_string "$1"
    : $((_data_$argv_ptr = $addr))
    : $((argv_ptr++))
    shift
  done
  push_stack $t

  run_instructions
}

run $@ < "$1"
