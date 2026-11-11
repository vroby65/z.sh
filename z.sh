#!/usr/bin/env bash
# z.sh — a small terminal editor. Editing and rendering use Bash builtins.

Z_VERSION=0.1.0
Z_HISTORY_LIMIT=100

z_reset() {
    text='' saved='' file='' pos=0 anchor=-1 clipboard=''
    top=0 left=0 rows=24 cols=80 height=21 gutter=5
    message='' query='' running=1 goal=-1 key='' reply=''
    undo_text=() undo_pos=() redo_text=() redo_pos=()
    input_queue='' input_char='' resize_pending=0
}

z_load() {
    local path=$1 data=''
    if [[ -e $path ]]; then
        [[ -f $path && -r $path ]] || { message='File non leggibile o non regolare'; return 1; }
        # A successful read with a NUL delimiter means this is a binary file.
        if IFS= read -r -d '' data < "$path"; then
            message='File binario: i byte NUL non sono supportati'; return 1
        fi
    elif [[ -L $path ]]; then
        message='Collegamento simbolico senza destinazione'; return 1
    elif [[ ! -d ${path%/*} && $path == */* ]]; then
        message='La cartella del file non esiste'; return 1
    fi
    text=$data saved=$data file=$path pos=0 anchor=-1 top=0 left=0
}

z_save() {
    local target=$file temp dir
    [[ -n $target ]] || { message='Specificare un nome con Ctrl+S'; return 1; }
    if [[ -L $target ]]; then
        target=$(readlink -f -- "$target") || { message='Destinazione del collegamento non valida'; return 1; }
        [[ -f $target ]] || { message='Destinazione del collegamento non valida'; return 1; }
    fi
    [[ ! -e $target || -f $target ]] || { message='La destinazione non è un file regolare'; return 1; }
    [[ ! -e $target || -w $target ]] || { message='File non scrivibile'; return 1; }
    dir=${target%/*}; [[ $target == */* ]] || dir=.
    temp=$(mktemp -- "$dir/.z.sh.XXXXXXXX") || { message='Impossibile creare il file temporaneo'; return 1; }
    if [[ -e $target ]]; then
        if ! cp -p -- "$target" "$temp"; then
            rm -f -- "$temp"; message='Impossibile preservare i permessi'; return 1
        fi
    else
        # mktemp deliberately keeps new files private (0600).
        :
    fi
    if printf '%s' "$text" > "$temp" && mv -f -- "$temp" "$target"; then
        saved=$text message='Salvato'; return 0
    fi
    rm -f -- "$temp"
    message='Salvataggio fallito: il buffer resta modificato'; return 1
}

z_checkpoint() {
    undo_text+=("$text"); undo_pos+=("$pos")
    if (( ${#undo_text[@]} > Z_HISTORY_LIMIT )); then
        undo_text=("${undo_text[@]:1}"); undo_pos=("${undo_pos[@]:1}")
    fi
    redo_text=() redo_pos=()
}

z_undo() {
    local n=${#undo_text[@]}
    (( n )) || { message='Niente da annullare'; return; }
    redo_text+=("$text"); redo_pos+=("$pos")
    text=${undo_text[n-1]} pos=${undo_pos[n-1]} anchor=-1 goal=-1
    unset 'undo_text[n-1]' 'undo_pos[n-1]'
}

z_redo() {
    local n=${#redo_text[@]}
    (( n )) || { message='Niente da ripetere'; return; }
    undo_text+=("$text"); undo_pos+=("$pos")
    text=${redo_text[n-1]} pos=${redo_pos[n-1]} anchor=-1 goal=-1
    unset 'redo_text[n-1]' 'redo_pos[n-1]'
}

z_selection() {
    start=$pos end=$pos
    if (( anchor >= 0 )); then
        if (( anchor < pos )); then start=$anchor; else end=$anchor; fi
    fi
    (( end > start ))
}

z_insert() {
    local value=$1 start end
    z_selection || :
    [[ -n $value || $end != "$start" ]] || return
    z_checkpoint
    text=${text:0:start}$value${text:end}
    pos=$((start + ${#value})) anchor=-1 goal=-1
}

z_backspace() {
    local start end
    if z_selection; then z_insert ''; return; fi
    (( pos > 0 )) || return
    anchor=$((pos-1)); z_insert ''
}

z_delete() {
    local start end
    if z_selection; then z_insert ''; return; fi
    (( pos < ${#text} )) || return
    anchor=$((pos+1)); z_insert ''
}

z_copy() {
    local start end
    if z_selection; then clipboard=${text:start:end-start}; message='Selezione copiata'
    else message='Selezionare con Shift+frecce o Ctrl+A'; fi
}

z_cut() {
    local start end
    if z_selection; then z_copy; z_insert ''; else message='Nessuna selezione'; fi
}

z_location() {
    local prefix=${text:0:pos} tail
    tail=${prefix##*$'\n'}
    column=${#tail} line_start=$((pos-column))
    prefix=${prefix//[^$'\n']/}
    row=${#prefix}
    tail=${text:pos}; tail=${tail%%$'\n'*}
    line_end=$((pos+${#tail}))
}

z_move() {
    local direction=$1 selecting=${2:-0} row column line_start line_end previous next length
    if (( selecting )); then (( anchor >= 0 )) || anchor=$pos; else anchor=-1; fi
    z_location
    case $direction in
        left) (( pos > 0 )) && ((pos-=1)); goal=-1 ;;
        right) (( pos < ${#text} )) && ((pos+=1)); goal=-1 ;;
        home) pos=$line_start; goal=-1 ;;
        end) pos=$line_end; goal=-1 ;;
        top) pos=0; goal=-1 ;;
        bottom) pos=${#text}; goal=-1 ;;
        up|down)
            (( goal >= 0 )) || goal=$column
            if [[ $direction == up ]] && (( line_start > 0 )); then
                previous=${text:0:line_start-1}; previous=${previous##*$'\n'}
                length=${#previous}; pos=$((line_start-1-length))
                (( goal < length )) && ((pos+=goal)) || ((pos+=length))
            elif [[ $direction == down ]] && (( line_end < ${#text} )); then
                next=${text:line_end+1}; next=${next%%$'\n'*}
                length=${#next}; pos=$((line_end+1))
                (( goal < length )) && ((pos+=goal)) || ((pos+=length))
            fi ;;
    esac
    return 0
}

z_find() {
    local needle=$1 offset=${2:-$((pos+1))} part prefix
    [[ -n $needle ]] || return 1
    part=${text:offset}
    if [[ $part == *"$needle"* ]]; then
        prefix=${part%%"$needle"*}; pos=$((offset+${#prefix}))
    elif [[ $text == *"$needle"* ]]; then
        prefix=${text%%"$needle"*}; pos=${#prefix}
    else message="Non trovato: $needle"; return 1
    fi
    anchor=$((pos+${#needle})) goal=-1 message="Trovato: $needle (Ctrl+N: successivo)"
}

# Render untrusted file names and text as printable text, never terminal commands.
z_safe() {
    local value=$1 char i
    safe=''
    for ((i=0; i<${#value}; i++)); do
        char=${value:i:1}
        case $char in
            [$'\001'-$'\037'$'\177'-$'\237']) safe+='?' ;;
            *) safe+=$char ;;
        esac
    done
}

z_size() {
    local size
    size=$(stty size <&3) || size='24 80'
    IFS=' ' read -r rows cols <<< "$size"
    (( rows >= 4 )) || rows=4
    (( cols >= 12 )) || cols=12
    height=$((rows-3))
}

z_render() {
    local row column line_start line_end prefix number count offset=0 index=0
    local rest=$text current visible char expanded visual=0 cursor_col=0 i r start end
    local screen=$'\e[?25l\e[H' label dirty='' style='' next_style='' quoted='' escaped=0 comment=0
    z_location
    prefix=${text//[^$'\n']/}; count=$((${#prefix}+1))
    gutter=$((${#count}+2)); (( gutter >= 4 )) || gutter=4
    (( gutter < cols-2 )) || gutter=4
    (( row < top )) && top=$row
    (( row >= top+height )) && top=$((row-height+1))
    prefix=${text:line_start:column}
    for ((i=0; i<${#prefix}; i++)); do
        if [[ ${prefix:i:1} == $'\t' ]]; then ((cursor_col+=4-cursor_col%4)); else ((cursor_col+=1)); fi
    done
    (( cursor_col < left )) && left=$cursor_col
    (( cursor_col >= left+cols-gutter )) && left=$((cursor_col-cols+gutter+1))
    [[ $text == "$saved" ]] || dirty=' *'
    z_safe "${file:-[nuovo file]}"; label=" z.sh | $safe$dirty"
    screen+=$'\e[1;44;97m'${label:0:cols}$'\e[K\e[0m'
    z_selection || :
    for ((r=0; r<height;)); do
        if (( index < top )); then
            current=${rest%%$'\n'*}; offset=$((offset+${#current}+1))
            if [[ $rest == *$'\n'* ]]; then rest=${rest#*$'\n'}; ((index+=1)); continue; fi
        fi
        screen+=$'\r\n\e[0m\e[K'
        if (( index < count )); then
            current=${rest%%$'\n'*}
            printf -v number '%*d ' "$((gutter-1))" "$((index+1))"
            screen+=$'\e[90m'$number$'\e[0m'
            visual=0 style='' quoted='' escaped=0 comment=0
            for ((i=0; i<${#current}; i++)); do
                char=${current:i:1}; expanded=$char; next_style=''
                # Deliberately small, line-local shell highlighting.
                if [[ $file == *.sh || $file == */.bashrc || $file == .bashrc ]]; then
                    if (( comment )); then next_style=$'\e[90m'
                    elif [[ -n $quoted ]]; then
                        next_style=$'\e[32m'
                        if (( escaped )); then escaped=0
                        elif [[ $char == \\ && $quoted == '"' ]]; then escaped=1
                        elif [[ $char == "$quoted" ]]; then quoted=''; fi
                    elif [[ $char == '#' && ( $i == 0 || ${current:i-1:1} == [[:space:]] ) ]]; then
                        comment=1; next_style=$'\e[90m'
                    elif [[ $char == '"' || $char == "'" ]]; then quoted=$char; next_style=$'\e[32m'
                    elif [[ $char == '$' ]]; then next_style=$'\e[36m'
                    fi
                fi
                if (( offset+i >= start && offset+i < end )); then next_style=$'\e[7m'; fi
                if [[ $char == $'\t' ]]; then printf -v expanded '%*s' "$((4-visual%4))" ''
                else z_safe "$char"; expanded=$safe; fi
                for ((number=0; number<${#expanded}; number++)); do
                    if (( visual >= left && visual < left+cols-gutter )); then
                        if [[ $style != "$next_style" ]]; then screen+=$'\e[0m'$next_style; style=$next_style; fi
                        screen+=${expanded:number:1}
                    fi
                    ((visual+=1))
                done
                (( visual >= left+cols-gutter )) && break
            done
            offset=$((offset+${#current}+1))
            if [[ $rest == *$'\n'* ]]; then rest=${rest#*$'\n'}; else rest=''; fi
        else screen+=$'\e[90m~\e[0m'; fi
        ((index+=1, r+=1))
    done
    label=" F1 aiuto | F2 salva | F7 cerca | F10 salva/esci | $((row+1)):$((column+1))"
    screen+=$'\r\n\e[0;7m'${label:0:cols}$'\e[K\e[0m\r\n'
    z_safe "$message"; screen+=${safe:0:cols}$'\e[K'
    printf -v label '\e[%d;%dH\e[?25h' "$((row-top+2))" "$((cursor_col-left+gutter+1))"
    printf '%s%s' "$screen" "$label" >&3
}

# Bash's read -n/-N/-s switches the TTY to cbreak internally, re-enabling
# ISIG and ICRNL. A normal timed read leaves our raw settings intact. Queue
# its partial result and restore the newline consumed on a successful read.
z_read_char() {
    local chunk='' status=0
    if [[ -z $input_queue ]]; then
        IFS= read -r -t "${1:-0.02}" -u 3 chunk || status=$?
        input_queue=$chunk
        (( status == 0 )) && input_queue+=$'\n'
    fi
    [[ -n $input_queue ]] || return 1
    input_char=${input_queue:0:1}
    input_queue=${input_queue:1}
}

z_read_key() {
    local char seq='' i
    if (( resize_pending )); then resize_pending=0; z_size; z_render; fi
    key=''
    z_read_char || return 1
    char=$input_char
    if [[ $char != $'\e' ]]; then key=$char; return 0; fi
    if ! z_read_char 0.04; then key=ESC; return 0; fi
    char=$input_char
    seq=$char
    if [[ $char == '[' || $char == O ]]; then
        for ((i=0; i<24; i++)); do
            z_read_char 0.04 || break
            char=$input_char
            seq+=$char
            [[ $char == [a-zA-Z~] ]] && break
        done
    fi
    case $seq in
        '[A'|OA) key=UP ;; '[B'|OB) key=DOWN ;; '[C'|OC) key=RIGHT ;; '[D'|OD) key=LEFT ;;
        '[H'|OH|'[1~'|'[7~') key=HOME ;; '[F'|OF|'[4~'|'[8~') key=END ;;
        '[1;5H'|'[7;5~') key=TOP ;; '[1;5F'|'[8;5~') key=BOTTOM ;;
        '[1;2A') key=SHIFT_UP ;; '[1;2B') key=SHIFT_DOWN ;;
        '[1;2C') key=SHIFT_RIGHT ;; '[1;2D') key=SHIFT_LEFT ;;
        '[1;2H') key=SHIFT_HOME ;; '[1;2F') key=SHIFT_END ;;
        '[3~') key=DELETE ;; '[5~') key=PAGEUP ;; '[6~') key=PAGEDOWN ;;
        OP|'[11~') key=HELP ;; OQ|'[12~') key=SAVE ;;
        '[18~') key=SEARCH ;; '[21~') key=SAVE_EXIT ;;
        '[200~') key=PASTE ;;
        *) key=UNKNOWN ;;
    esac
}

z_collect_paste() {
    local char
    paste_text=''
    while (( running )); do
        z_read_char || continue
        char=$input_char
        paste_text+=$char
        if [[ $paste_text == *$'\e[201~' ]]; then
            paste_text=${paste_text%$'\e[201~'}
            paste_text=${paste_text//$'\r\n'/$'\n'}
            paste_text=${paste_text//$'\r'/$'\n'}
            return
        fi
    done
}

z_read_paste() {
    # Treat a bracketed paste as one edit, including embedded control keys.
    z_collect_paste
    z_insert "$paste_text"
}

z_prompt() {
    local label=$1 value=${2:-} char safe i
    while :; do
        z_safe "$label$value"
        printf '\e[%d;1H\e[0m%s\e[K' "$rows" "${safe:0:cols}" >&3
        z_read_key || continue
        case $key in
            $'\r'|$'\n') reply=$value; return 0 ;;
            ESC|$'\003') return 1 ;;
            $'\177'|$'\b') [[ -z $value ]] || value=${value:0:${#value}-1} ;;
            PASTE)
                z_collect_paste
                for ((i=0; i<${#paste_text}; i++)); do
                    char=${paste_text:i:1}
                    [[ $char == [[:cntrl:]] ]] || value+=$char
                done ;;
            *) [[ ${#key} == 1 && $key != [[:cntrl:]] ]] && value+=$key ;;
        esac
    done
}

z_save_interactive() {
    if [[ -z $file ]]; then
        z_prompt 'Salva come: ' || { message='Salvataggio annullato'; return 1; }
        [[ -n $reply ]] || { message='Nome file vuoto'; return 1; }
        if [[ -e $reply || -L $reply ]]; then
            local candidate=$reply
            z_prompt 'Il file esiste. Sovrascrivere? (s/N): ' || return 1
            [[ $reply == s || $reply == S ]] || return 1
            file=$candidate
        else file=$reply; fi
    fi
    z_save
}

z_quit() {
    if [[ $text != "$saved" ]]; then
        z_prompt 'Modifiche non salvate: (s)alva / (e)sci / Invio annulla: ' || return
        case $reply in
            s|S) z_save_interactive || return ;;
            e|E) : ;;
            *) message='Uscita annullata'; return ;;
        esac
    fi
    running=0
}

z_help() {
    local lines=(
        'z.sh — comandi'
        ''
        'F2 / Ctrl+S       Salva'
        'F10              Salva ed esci'
        'Esc / Ctrl+Q     Esci (con conferma se modificato)'
        'F7 / Ctrl+F      Cerca testo letterale'
        'Ctrl+N           Occorrenza successiva'
        'Ctrl+Z / Ctrl+Y  Annulla / ripeti'
        'Shift+frecce     Seleziona (anche Home/End)'
        'Ctrl+A           Seleziona tutto'
        'Ctrl+C/X/V       Copia / taglia / incolla interno'
        'Home / End       Inizio / fine riga'
        'Ctrl+Home/End    Inizio / fine documento'
        'PgUp / PgDown    Pagina precedente / successiva'
        'Tab              Tabulazione (4 colonne)'
        ''
        'Incolla dal terminale: supporto bracketed paste.'
        'Premere un tasto per tornare.'
    ) line n=0
    printf '\e[2J\e[H' >&3
    for line in "${lines[@]}"; do
        (( n < rows-1 )) || break
        printf '%s\r\n' "${line:0:cols}" >&3; ((n+=1))
    done
    until z_read_key; do :; done
    [[ $key != PASTE ]] || z_collect_paste
    printf '\e[2J' >&3
}

z_dispatch() {
    local i direction
    case $key in
        UP|DOWN|LEFT|RIGHT|HOME|END|TOP|BOTTOM) direction=${key,,}; z_move "$direction" ;;
        SHIFT_*) direction=${key#SHIFT_}; z_move "${direction,,}" 1 ;;
        PAGEUP|PAGEDOWN)
            direction=up; [[ $key == PAGEDOWN ]] && direction=down
            for ((i=0; i<height; i++)); do z_move "$direction"; done ;;
        $'\177'|$'\b') z_backspace ;; DELETE) z_delete ;;
        $'\r'|$'\n') z_insert $'\n' ;; $'\t') z_insert $'\t' ;;
        SAVE|$'\023') z_save_interactive ;;
        SAVE_EXIT) if z_save_interactive; then running=0; fi ;;
        SEARCH|$'\006') if z_prompt 'Cerca: ' "$query"; then query=$reply; z_find "$query" 0; fi ;;
        $'\016') z_find "$query" ;;
        $'\032') z_undo ;; $'\031') z_redo ;;
        $'\001') anchor=0; pos=${#text}; goal=-1 ;;
        $'\003') z_copy ;; $'\030') z_cut ;; $'\026') z_insert "$clipboard" ;;
        ESC|$'\021') z_quit ;;
        HELP) z_help ;;
        PASTE) z_read_paste ;;
        *) [[ ${#key} == 1 && $key != [[:cntrl:]] ]] && z_insert "$key" ;;
    esac
    return 0
}

z_cleanup() {
    if [[ -n ${tty_state:-} ]]; then
        printf '\e[0m\e[?25h\e[?2004l\e[?1049l' >&3
        stty "$tty_state" <&3
        tty_state=''
        exec 3>&-
    fi
}

z_main() {
    if (( BASH_VERSINFO[0] < 4 )); then printf 'z.sh richiede Bash 4 o successivo.\n' >&2; return 1; fi
    case ${1:-} in
        --help|-h)
            printf 'z.sh %s — editor da terminale in Bash\nUso: z.sh [--] [file]\nF1 aiuto · F2 salva · F7 cerca · F10 salva/esci · Esc esci\n' "$Z_VERSION"; return ;;
        --version) printf 'z.sh %s\n' "$Z_VERSION"; return ;;
        --) shift ;;
        -*) printf 'Opzione sconosciuta: %s\n' "$1" >&2; return 2 ;;
    esac
    (( $# <= 1 )) || { printf 'Uso: z.sh [--] [file]\n' >&2; return 2; }
    z_reset
    if (( $# )) && ! z_load "$1"; then printf 'z.sh: %s\n' "$message" >&2; return 1; fi
    if ! { exec 3<> /dev/tty; } 2>/dev/null; then printf 'z.sh: serve un terminale interattivo.\n' >&2; return 1; fi
    tty_state=$(stty -g <&3) || { exec 3>&-; return 1; }
    trap z_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'resize_pending=1' WINCH
    stty raw -echo <&3 || return 1
    printf '\e[?1049h\e[?2004h\e[2J' >&3
    z_size
    message='F1: comandi | Ctrl+S: salva | Ctrl+Q: esci'
    while (( running )); do
        z_render
        # Idle timeouts do not repaint the entire screen.
        until z_read_key; do :; done
        z_dispatch
    done
    z_cleanup
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then z_main "$@"; fi
