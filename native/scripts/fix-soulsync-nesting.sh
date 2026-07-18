#!/bin/bash
# Undo the SoulSync move bug of 2026-06-05.
#
# SoulSync recreated its ABSOLUTE source path inside each destination album:
#   /Muziek/<Artist>/<Album>/Volumes/4tbdrive/SoulSync-Staging/<Artist>/<Album>/<rest>
# instead of moving <rest> into /Muziek/<Artist>/<Album>/<rest>.
#
# Per nested file, exactly one of three things is true:
#   DUP    the file also exists at the normal place AND is byte-identical -> delete the nested copy
#   UNIEK  no counterpart at the normal place                             -> move it up, keep the music
#   CONFL  a counterpart exists but differs                               -> leave alone, report it
#
# The analyzer stores an absolute file_path per track and serves /audio from it,
# so any row pointing into the nested tree is repointed at the surviving file —
# otherwise those tracks stop playing.
#
# Dry run by default. Nothing is deleted or moved without --apply.
set -uo pipefail

MUZIEK="/Volumes/4tbdrive/Muziek"
NEST_MARKER="/Volumes/4tbdrive/SoulSync-Staging/"
DB="$HOME/Library/Application Support/RoonSageAnalyzer/analyzer.db"
# --apply        verplaats de unieke bestanden EN verwijder de duplicaten
# --apply-moves  verplaats alleen; verwijder niets (omkeerbaar, geen ruimtewinst)
APPLY=0; MOVES_ONLY=0
case "${1:-}" in
    --apply)       APPLY=1 ;;
    --apply-moves) APPLY=1; MOVES_ONLY=1 ;;
esac
# De byte-vergelijking is er alleen om verwijderen te mogen verantwoorden. Wordt
# er niets verwijderd, dan is hij overbodig — en hij kost ~45 min aan schijf-I/O.
NEED_CMP=1; [ "$MOVES_ONLY" -eq 1 ] && NEED_CMP=0

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
: > "$WORK/dup" ; : > "$WORK/uniek" ; : > "$WORK/confl"
dup_bytes=0; uniek_bytes=0; confl_bytes=0

echo "── nested trees zoeken onder $MUZIEK"
find "$MUZIEK" -maxdepth 3 -type d -name "Volumes" -print0 > "$WORK/roots"
roots=$(tr -dc '\0' < "$WORK/roots" | wc -c | tr -d ' ')
echo "   $roots gevonden"

# Classify every file in every nested tree.
while IFS= read -r -d '' root; do
    while IFS= read -r -d '' f; do
        case "$f" in
            *"$NEST_MARKER"*) ;;
            *) continue ;;                       # not the pattern we understand — skip
        esac
        album="${f%%$NEST_MARKER*}"              # /Muziek/<Artist>/<Album>
        album="${album%/Volumes}"
        rest="${f#*$NEST_MARKER}"                # <Artist>/<Album>/<rest>
        rest="${rest#*/}"; rest="${rest#*/}"     # drop the duplicated Artist/Album
        orig="$album/$rest"
        size=$(stat -f%z "$f" 2>/dev/null || echo 0)
        if [ ! -e "$orig" ]; then
            printf '%s\0%s\0' "$f" "$orig" >> "$WORK/uniek"; uniek_bytes=$((uniek_bytes+size))
        elif [ "$NEED_CMP" -eq 0 ]; then
            printf '%s\0%s\0' "$f" "$orig" >> "$WORK/dup";   dup_bytes=$((dup_bytes+size))
        elif cmp -s "$f" "$orig"; then
            printf '%s\0%s\0' "$f" "$orig" >> "$WORK/dup";   dup_bytes=$((dup_bytes+size))
        else
            printf '%s\0%s\0' "$f" "$orig" >> "$WORK/confl"; confl_bytes=$((confl_bytes+size))
        fi
    done < <(find "$root" -type f -print0 2>/dev/null)
done < "$WORK/roots"

n_dup=$(( $(tr -dc '\0' < "$WORK/dup" | wc -c) / 2 ))
n_uniek=$(( $(tr -dc '\0' < "$WORK/uniek" | wc -c) / 2 ))
n_confl=$(( $(tr -dc '\0' < "$WORK/confl" | wc -c) / 2 ))

echo
echo "── plan"
if [ "$NEED_CMP" -eq 1 ]; then
    printf '   DUP   verwijderen : %6d bestanden  %5d GB (byte-identiek geverifieerd)\n' "$n_dup" "$((dup_bytes/1024/1024/1024))"
else
    printf '   DUP   blijft staan : %6d bestanden  %5d GB (tegenhanger aanwezig, NIET vergeleken)\n' "$n_dup" "$((dup_bytes/1024/1024/1024))"
fi
printf '   UNIEK verplaatsen : %6d bestanden  %5d MB (bestaat nergens anders)\n' "$n_uniek" "$((uniek_bytes/1024/1024))"
printf '   CONFL met rust    : %6d bestanden  %5d MB (verschilt van het origineel)\n' "$n_confl" "$((confl_bytes/1024/1024))"

if [ -s "$WORK/confl" ]; then
    echo "   conflicten:"
    while IFS= read -r -d '' f && IFS= read -r -d '' o; do
        printf '     %s\n' "${f#$MUZIEK/}"
    done < "$WORK/confl" | head -10
fi

echo
echo "── voorbeelden"
while IFS= read -r -d '' f && IFS= read -r -d '' o; do printf '   DUP   %s\n' "${f#$MUZIEK/}"; done < "$WORK/dup" | head -3
while IFS= read -r -d '' f && IFS= read -r -d '' o; do printf '   UNIEK %s\n     -> %s\n' "${f#$MUZIEK/}" "${o#$MUZIEK/}"; done < "$WORK/uniek" | head -3

if [ "$APPLY" -eq 0 ]; then
    echo
    echo "DROOGLOOP — er is niets gewijzigd. Uitvoeren: $0 --apply"
    exit 0
fi

echo
echo "── uitvoeren"
[ -f "$DB" ] && cp "$DB" "$DB.pre-soulsync-fix" && echo "   DB-backup: $DB.pre-soulsync-fix"

repoint() {   # $1 = oud pad, $2 = nieuw pad — verhuis de analyzer-rij mee
    [ -f "$DB" ] || return 0
    # stdout gedempt: PRAGMA echoot zijn waarde en zou de voortgang onleesbaar maken
    sqlite3 "$DB" "PRAGMA busy_timeout=60000;
      UPDATE OR IGNORE track_features SET file_path = '$(printf '%s' "$2" | sed "s/'/''/g")'
       WHERE file_path = '$(printf '%s' "$1" | sed "s/'/''/g")';" >/dev/null 2>&1
}

verwijderd=0; verplaatst=0; overgeslagen=0
if [ "$MOVES_ONLY" -eq 1 ]; then
    echo "   duplicaten worden NIET verwijderd (--apply-moves)"
else
    while IFS= read -r -d '' f && IFS= read -r -d '' o; do
        if cmp -s "$f" "$o"; then                # hercontrole vlak voor het wissen
            rm -f "$f" && verwijderd=$((verwijderd+1)) && repoint "$f" "$o"
        else
            overgeslagen=$((overgeslagen+1))     # veranderd sinds de scan
        fi
    done < "$WORK/dup"
fi

while IFS= read -r -d '' f && IFS= read -r -d '' o; do
    if [ -e "$o" ]; then
        overgeslagen=$((overgeslagen+1))         # ondertussen ontstaan
    else
        mkdir -p "$(dirname "$o")" && mv "$f" "$o" && verplaatst=$((verplaatst+1)) && repoint "$f" "$o"
    fi
done < "$WORK/uniek"

# Alleen lege mappen binnen de geneste bomen opruimen — nooit rm -rf.
leeg=0
while IFS= read -r -d '' root; do
    while find "$root" -type d -empty -print -delete 2>/dev/null | grep -q .; do leeg=$((leeg+1)); done
    rmdir "$root" 2>/dev/null && leeg=$((leeg+1))
done < "$WORK/roots"

echo "   verwijderd: $verwijderd · verplaatst: $verplaatst · overgeslagen: $overgeslagen · mappen opgeruimd: $leeg"
echo "   resterende geneste bestanden: $(find "$MUZIEK" -path "*$NEST_MARKER*" -type f 2>/dev/null | wc -l | tr -d ' ')"
