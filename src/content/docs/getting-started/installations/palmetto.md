---
title: Palmetto
description: Run preinstalled Neurodesk tools on Clemson University's Palmetto 2 cluster.
sidebar:
  order: 6
---

Neurocontainers are already installed on [Palmetto 2, Clemson University's HPC cluster](https://docs.rcd.clemson.edu/palmetto/about/). Load them with `ml neurocontainers` inside a compute job.

## Connect via SSH

You need an active Palmetto account and Duo authentication. Follow Clemson's [getting started guide](https://docs.rcd.clemson.edu/palmetto/starting/) if you do not have access yet.

Run this command in a terminal on your computer, replacing `username` with your Clemson username:

```bash
ssh username@slogin.palmetto.clemson.edu
```

Complete the password and Duo prompts.

To use a shorter command, add this entry to `~/.ssh/config` on your computer:

```text
Host palmetto
	HostName slogin.palmetto.clemson.edu
	User username
```

You can then connect with `ssh palmetto`.

## Choose where to store files

Use `/scratch/$USER` for temporary inputs and outputs. Copy results you need to keep into home or project storage. Shared scratch is not backed up and files are eligible for deletion after 30 days without access, modification, or metadata changes. Local scratch, available through `$TMPDIR` inside a job, is deleted when the job ends. See Clemson's [scratch storage policy](https://docs.rcd.clemson.edu/palmetto/storage/spaces/scratch/).

Check your storage quota on a login node:

```bash
checkquota
```

Home storage currently provides 250 GB per user. For larger datasets, arrange project storage with your lab. See the [storage overview](https://docs.rcd.clemson.edu/palmetto/storage/store/) for current capacities and backup coverage.

## Use Neurocontainers

Request an interactive compute job:

```bash
salloc --partition=hpcnirc --nodes=1 --ntasks=1 --cpus-per-task=4 --mem=16G --time=02:00:00
```

Once the allocation starts, load Neurocontainers and list the available tools:

```bash
ml neurocontainers
ml av
```

For more info, see the [scheduler guide](https://docs.rcd.clemson.edu/palmetto/job_management/sched/).

### Load a Neurodesk tool

```bash
ml avail fsl
ml fsl
export APPTAINER_BINDPATH="/scratch/$USER,$TMPDIR"
command -v bet
```

The final command should print the path to FSL's `bet` wrapper. If your data is in project storage, append the actual project directory to `APPTAINER_BINDPATH`, separated by a comma. Bind only paths that exist and that you can access.

Run `ml neurocontainers`, load your tool module, and set the bind paths in each new session and batch script. To use a specific tool version, select its full module name from `ml avail`.

When you have finished the interactive session, release the allocation:

```bash
exit
```

## Submit a batch job

The following example extracts a brain image from an input T1-weighted NIfTI image. Adjust memory and wall time for your data. Clemson's [job submission guide](https://docs.rcd.clemson.edu/palmetto/job_management/submit/) explains the resource options.

On Palmetto, create a working directory:

```bash
mkdir -p "/scratch/$USER/neurodesk-example/logs"
cd "/scratch/$USER/neurodesk-example"
```

Save this script as `bet.sbatch` in that directory:

```bash
#!/bin/bash
#SBATCH --job-name=neurodesk-bet
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --time=00:30:00
#SBATCH --output=logs/%x_%j.out
#SBATCH --error=logs/%x_%j.err
#SBATCH --no-requeue
#SBATCH --partition=hpcnirc

set -e
ml neurocontainers
export APPTAINER_BINDPATH="/scratch/$USER,$TMPDIR"
ml fsl

input=${1:?Pass the path to an input NIfTI image}
output=${2:?Pass the output image path}
srun bet "$input" "$output" -m
```

Transfer your input image to the working directory as `T1w.nii.gz`. Alternatively, download a sample T1-weighted image from [OpenNeuro dataset ds000114](https://openneuro.org/datasets/ds000114), subject `sub-01`, session `ses-test`:

```bash
cd "/scratch/$USER/neurodesk-example"
curl --fail --location --output T1w.nii.gz \
	https://s3.amazonaws.com/openneuro.org/ds000114/sub-01/ses-test/anat/sub-01_ses-test_T1w.nii.gz
```

Then submit from that directory:

```bash
sbatch bet.sbatch "$PWD/T1w.nii.gz" "$PWD/T1w_brain.nii.gz"
```

Create `logs` before submission because Slurm opens the log files before running your script. A successful job produces `T1w_brain.nii.gz` and a brain mask. 

Palmetto owner jobs can preempt other jobs. Batch jobs normally requeue after preemption, while interactive jobs are cancelled. This example uses `--no-requeue` to prevent an automatic restart that could overwrite partial outputs. Remove that option only after making your workflow safe to restart. See Clemson's [preemption rules](https://docs.rcd.clemson.edu/palmetto/job_management/sched/#preemption).

### Monitor and cancel jobs

Check your queued and running jobs:

```bash
squeue --me
```

If you monitor repeatedly, leave at least 60 seconds between Slurm queries:

```bash
watch -n 60 'squeue --me'
```

Cancel a job by replacing `123456` with the job ID returned by `sbatch`:

```bash
scancel 123456
```

For many subjects, use [Slurm job arrays](https://docs.rcd.clemson.edu/palmetto/job_management/arrays/) instead of a rapid loop of submissions. Retain the module and bind-path setup in each task.

## Run graphical tools through Open OnDemand

Use Clemson's [Palmetto Desktop](https://docs.rcd.clemson.edu/openod/apps/desktop/) to run Neurodesk graphical tools on a compute node:

1. Open [Clemson Open OnDemand](https://ondemand.rcd.clemson.edu/) and authenticate with your Clemson account and Duo.
2. Select **Interactive Apps**, then **Palmetto Desktop**.
3. Request the CPU cores, memory, and wall time your application needs. The desktop itself does not require a GPU.
4. Select **Launch** and wait for the job to start.
5. Select **Launch Palmetto Desktop**, then open a terminal in the desktop.

In the desktop terminal, load ITK-SNAP and start it:

```bash
ml neurocontainers
export APPTAINER_BINDPATH="/scratch/$USER,$TMPDIR"
ml itksnap
itksnap
```

This uses Clemson's desktop with individual Neurodesk containers. For OpenGL rendering problems, follow the [Palmetto Desktop VirtualGL instructions](https://docs.rcd.clemson.edu/openod/apps/desktop/#virtualgl).

Save your work before the allocation ends. End the session through Open OnDemand when you finish. Use batch jobs for unattended processing because [interactive sessions can terminate after disconnection or inactivity](https://docs.rcd.clemson.edu/palmetto/job_management/types/).

## Transfer data

Use Clemson's dedicated data transfer nodes or Globus for imaging datasets. Run these examples on your computer, replacing both occurrences of `username` with your Clemson username:

```bash
scp T1w.nii.gz username@hpcdtn01.rcd.clemson.edu:/scratch/username/neurodesk-example/
scp username@hpcdtn01.rcd.clemson.edu:/scratch/username/neurodesk-example/T1w_brain.nii.gz .
```

The destination directory must already exist. If the first transfer node is unavailable, use `hpcdtn02.rcd.clemson.edu`. 

For larger transfers, follow Clemson's [data transfer guide](https://docs.rcd.clemson.edu/palmetto/transfer/overview/) to use Globus. Login-node transfers are limited to less than 100 MB total, and Open OnDemand transfers to less than 50 MB total.
