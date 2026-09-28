#!/usr/bin/env bash
# After `breath36.py render` of the v2 subset plan: assemble -> 1x onsets -> speed axis on mobile01 -> speed onsets.
set -uo pipefail
cd "$(dirname "$0")/.."
PY=../concatenator-corpus/.venv/bin/python
export B36_WORK=$PWD/breath36b_work B36_OUT=$PWD/breath36b_voices B36_SUFFIX=_b
echo "=== $(date +%T) assemble"; $PY breath36.py assemble --collage-latent --silence-db=-36 --min-silence-ms 400 --min-seg-ms 1500 2>&1 | tail -1
echo "=== $(date +%T) onsets 1x"; $PY sharp/make_onsets.py 2>&1 | grep -v Warning | tail -1
R=/scratch/jonmyers/breath36b_speed
echo "=== $(date +%T) flac + upload"; mkdir -p $B36_OUT/_flac
ls $B36_OUT/v*_slot*.wav | xargs -P 8 -I{} sh -c 'f="{}"; b=$(basename "$f" .wav); [ -s "'$B36_OUT'/_flac/$b.flac" ] || ffmpeg -nostdin -hide_banner -loglevel error -y -i "$f" -c:a flac -sample_fmt s32 "'$B36_OUT'/_flac/$b.flac"'
cp $B36_OUT/voices.json $B36_OUT/_flac/
rsync -a $B36_OUT/_flac/ mobile01:$R/src/ 2>&1 | grep -v bashrc; rsync -a sharp/render_speed_axis.py ../accelerando/ncvi.py mobile01:$R/ 2>&1 | grep -v bashrc
echo "=== $(date +%T) speed render on mobile01"
ssh -o BatchMode=yes mobile01 "cd $R && CUDA_VISIBLE_DEVICES=1 /scratch/jonmyers/hackathon-flowedit/.venv/bin/python render_speed_axis.py --device cuda --voices-dir src --src-ext flac --out out --levels 1.5,2,3,4,6,8,10 --latent-cache latents > run.log 2>&1; tail -1 run.log; cd out && ls *.wav | xargs -P 8 -I{} sh -c 'f={}; [ -s \${f%.wav}.flac ] || ffmpeg -nostdin -hide_banner -loglevel error -y -i \$f -c:a flac -sample_fmt s32 \${f%.wav}.flac'; ls *.flac | wc -l" 2>&1 | grep -v bashrc
echo "=== $(date +%T) fetch"; mkdir -p $B36_OUT/speed $B36_OUT/_speed_flac
rsync -a --include='*.flac' --include='speed.json' --exclude='*' mobile01:$R/out/ $B36_OUT/_speed_flac/ 2>&1 | grep -v bashrc
ls $B36_OUT/_speed_flac/*.flac | xargs -P 8 -I{} sh -c 'f="{}"; b=$(basename "$f" .flac); ffmpeg -nostdin -hide_banner -loglevel error -y -i "$f" -c:a pcm_f32le "'$B36_OUT'/speed/$b.wav"'
cp $B36_OUT/_speed_flac/speed.json $B36_OUT/speed/
echo "=== $(date +%T) onsets speed"; $PY sharp/make_onsets.py --speed 2>&1 | grep -v Warning | tail -1
echo "B36B_DONE $(date +%T): $(ls $B36_OUT/v*_slot*.wav | wc -l) base files, $(ls $B36_OUT/speed/*.wav | wc -l) speed files"
