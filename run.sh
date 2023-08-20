#!/bin/bash

# Copyright 2020 Tomoki Hayashi
#  MIT License (https://opensource.org/licenses/MIT)

. ./cmd.sh || exit 1;
. ./path.sh || exit 1;

# basic settings
stage=-1              # stage to start
stop_stage=100        # stage to stop
verbose=1             # verbosity level (lower is less info)
world_size=1          # number of workers in training
distributed_init=     # file path for init_process_group in distributed training
nj=16     # number of parallel jobs in feature extraction

# NOTE(kan-bayashi): renamed to conf to avoid conflict in parse_options.sh
conf=conf/hifigan.v1.yaml
# conf=conf/multi_band_melgan.v2.yaml
sampling_rate=16000        # sampling frequency
fmax=7600       # maximum frequency
fmin=80         # minimum frequency
num_mels=80     # number of mel basis
fft_size=1024   # number of fft points
hop_size=160    # number of shift points
win_length=465  # window length

# speaker setting
part="all" # "clean" or "all"
             # if set to "clean", use only clean data
             # if set to "all", use clean + other data

# directory path setting
datadir=$PWD/data
featdir=$PWD/feats

# training related setting
tag=""     # tag for directory to save model
resume=""  # checkpoint path to resume training
           # (e.g. <path>/<to>/checkpoint-10000steps.pkl)

# decoding related setting
checkpoint=   # checkpoint path to be used for decoding
              # if not provided, the latest one will be used
              # (e.g. <path>/<to>/checkpoint-400000steps.pkl)

train_set="train_${part}" # name of training data directory
dev_set="dev_${part}"           # name of development data directory
eval_set="eval_${part}"         # name of evaluation data directory

# shellcheck disable=SC1091
. parse_options.sh || exit 1;

db_root=/mnt/lustre/sjtu/home/cpd30/dataset/tts/LibriTTS


set -eo pipefail

vqdir=feats/vqidx/

if [ -z "${tag}" ]; then
    expdir="exp/${train_set}_$(basename "${conf}" .yaml)"
else
    expdir="exp/${train_set}_${tag}"
fi
if [ "${stage}" -le 2 ] && [ "${stop_stage}" -ge 2 ]; then
    echo "Stage 2: Network training"
    [ ! -e "${expdir}" ] && mkdir -p "${expdir}"
    if [ -z $SLURM_ARRAY_TASK_ID ] ; then rank=0 ; else rank=$(($SLURM_ARRAY_TASK_ID-1)) ; fi
    if [ $world_size -gt 1 ] && [ -z $distributed_init ] ; then 
        echo "In distributed training, but --distributed_init is not specified."
        exit 1 ;
    fi
    echo "Hostname: `hostname`."
    echo "CUDA Devices: $CUDA_VISIBLE_DEVICES"
    echo "World size: $world_size"
    echo "Rank: $rank"
    echo "Training start. See the progress via ${expdir}/train.${rank}.log."
    ${cuda_cmd} --gpu 1 "${expdir}/log/train.${rank}.log" \
        train.py \
            --config "${conf}" \
            --train-wav-scp $datadir/${train_set}/wav.scp \
            --train-feats-scp ${datadir}/${train_set}/feats.scp \
            --train-num-frames $datadir/${train_set}/utt2num_frames \
            --dev-wav-scp ${datadir}/${dev_set}/wav.scp \
            --dev-feats-scp ${datadir}/${dev_set}/feats.scp \
            --dev-num-frames $datadir/${dev_set}/utt2num_frames \
            --vq-codebook $vqdir/codebook.npy \
            --outdir "${expdir}" \
            --resume "${resume}" \
            --sampling-rate ${sampling_rate} \
            --hop-size ${hop_size} \
            --num-mels ${num_mels} \
            --win-length ${win_length} \
            --world-size ${world_size} \
            --rank ${rank} \
            --distributed-init "${distributed_init}" \
            --verbose "${verbose}"
    echo "Successfully finished training."
fi

if [ "${stage}" -le 3 ] && [ "${stop_stage}" -ge 3 ]; then
    echo "Stage 3: Network decoding"
    # shellcheck disable=SC2012
    [ -z "${checkpoint}" ] && checkpoint="$(ls -dt "${expdir}"/*.pkl | head -1 || true)"
    outdir="${expdir}/synthesis/$(basename "${checkpoint}" .pkl)"
    for name in "${eval_set}"; do
        [ ! -e "${outdir}/${name}" ] && mkdir -p "${outdir}/${name}"
        select-feats 5-84 scp:${datadir}/feats.scp ark,scp:${featdir}/normed_fbank/${name}/feats.ark,${featdir}/normed_fbank/${name}/feats.scp
        python local/build_prompt_feat.py ${datadir}/${name}/utt2num_frames ${datadir}/${name}/utt2spk ${featdir}/normed_fbank/${name}/feats.scp 300 > ${datadir}/${name}/prompt.scp
        echo "Decoding start. See the progress via ${outdir}/${name}/decode.log."
                # --prompt-scp ${outdir}/${name}/prompt.scp \
        ${cuda_cmd} --gpu 1 "${outdir}/${name}/log/decode.log" \
            decode.py \
                --feats-scp ${datadir}/${name}/feats.scp \
                --prompt-scp ${datadir}/${name}/prompt.scp \
                --num-frames ${datadir}/${name}/utt2num_frames \
                --checkpoint "${checkpoint}" \
                --outdir "${outdir}/${name}/wav" \
                --verbose "${verbose}"
        echo "Successfully finished decoding of ${name} set."
    done
    echo "Successfully finished decoding."
fi
echo "Finished."
