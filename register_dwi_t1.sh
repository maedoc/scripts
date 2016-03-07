#!/bin/bash

# make t1 & parcseg in ras orientation, nifti format
for im in T1 aparc+aseg; do
	mri_convert --in_type mgz --out_type nii --out_orientation RAS \
		$FS/$SUBJ_ID/mri/${im}.mgz \
		$PRD/connectivity/${im}.nii.gz
done


# standardize parc orientation
fslreorient2std aparc+aseg.nii.gz aparc+aseg_reorient.nii.gz
"$FSL"fslview T1.nii.gz aparc+aseg_reorient.nii.gz -l "Cool" # TODO redo nibabel+mpl

# find xfm from diff to t1, apply to parc & t1

## find affine registration from diff to t1 w/ highest mutual information
"$FSL"flirt -in   lowb.nii.gz \
	    -ref  T1.nii.gz   \
	    -omat diffusion_2_struct.mat \
	    -out  lowb_2_struct.nii.gz \
	    -dof 12 -searchrx -180 180 -searchry -180 180 -searchrz -180 180 -cost mutualinfo

## invert transform
"$FSL"convert_xfm \
	-omat    diffusion_2_struct_inverse.mat \
	-inverse diffusion_2_struct.mat

## apply to parc
"$FSL"flirt -applyxfm \
	-in   aparc+aseg_reorient.nii.gz \
	-ref  lowb.nii.gz \
	-out  aparcaseg_2_diff.nii.gz \
	-init diffusion_2_struct_inverse.mat \
	-interp nearestneighbour

## apply to t1
"$FSL"flirt -applyxfm \
	-in   T1.nii.gz \
	-ref  lowb.nii.gz \
	-out  T1_2_diff.nii.gz \
	-init diffusion_2_struct_inverse.mat \
	-interp nearestneighbour

## check
"$FSL"fslview \
	T1_2_diff.nii.gz \
	lowb.nii.gz \
	aparcaseg_2_diff \
	-l "Cool"
