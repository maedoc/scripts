#!/bin/bash

######### import config
while getopts ":c:" opt; do
     case $opt in
     c)
         export CONFIG=$OPTARG
         echo "use config file $CONFIG" >&2
         if [ ! -f $CONFIG ]
         then
		 echo "config file unexistent" >&2
		 exit 1
         fi
         source "$CONFIG"
         ;;
     \?)
         echo "Invalid option: -$OPTARG" >&2
         exit 1
         ;;
     :)
         echo "Option -$OPTARG requires an argument." >&2
         exit 1
         ;;
    esac
done

if [ ! -n "$CONFIG" ]
then
    echo "you must provide a config file"
    exit 1
fi

if [ ! -n "$number_tracks" ]
then
    echo "config file does not provide the number_tracks parameter"
    exit 1
fi

if [ ! -n "$SUBJECTS_DIR" ]
then
    echo "you have to set the SUBJECTS_DIR environnement
    variable for FreeSurfer"
    exit 1
else
    export FS=$SUBJECTS_DIR
fi

# reusable functions
function log() {
	# TODO add date, verbosity, etc?
	echo "[scripts] $@"
}

function gen() {
	# get file & function names
	target=$1
	funcname=$2
	# remove those two arguments from arg list, rest go to function
	shift 2

	# TODO allow interactive remaking
	#if [ -e $target && $interactive=="yes" ]
	#then
	#    echo "remake $target? "
	#fi
		
	if [ ! -e $target ]
	then
		log "$target does not exist"
		log "generating $target with $funcname $target $@"
		$funcname $target $@
	else
		log "$target exists, not regenerating"
	fi
}

function convert_to_niigz() {
	mrconvert $2 $1
}

function fs_recon_all() {
	recon-all -i $2 -s $3 -all
}

function ascii_surface() {
	mris_convert $FS/$SUBJ_ID/surf/$2.pial $PRD/surface/$2.pial.asc
	mris_info $FS/$SUBJ_ID/surf/$2.pial >& $PRD/surface/${2}info.txt
	python extract_high.py $2
}

function remesh() {
	python txt2off.py $PRD/surface/${2}_vertices_high.txt \
		$PRD/surface/${2}_triangles_high.txt \
		$PRD/surface/${2}_high.off
	./remesher/cmdremesher/cmdremesher $PRD/surface/${2}_high.off $PRD/surface/${2}_low.off
	python off2txt.py $PRD/surface/${2}_low.off \
	    $PRD/surface/${2}_vertices_low.txt \
	    $PRD/surface/${2}_triangles_low.txt
}

function make_region_mapping () {
	# generate
	if [ -n "$matlab" ]
	then
		$matlab -r "rl='${2}';run region_mapping.m; quit;" -nodesktop -nodisplay
	else
		# TODO how does it know which hemisphere?
		sh region_mapping/distrib/run_region_mapping.sh $MCR
	fi
	# correct & check
	python correct_region_mapping.py ${2}
	python check_region_mapping.py ${2}
}

function make_zip() {
	wd=$1
	nm=$2
	shift 2
	pushd $wd > /dev/null
	zip $nm $@ -q
	popd > /dev/null
}

function finalize_surface_data_files() {
	make_zip $PRD/$SUBJ_ID/surface surface.zip vertices.txt triangles.txt
	cp $PRD/$SUBJ_ID/surface/region_mapping.txt $PRD/$SUBJ_ID/
}

function unify_region_mappings() {
	python reunify_both_regions.py
}

# make directory structure
mkdir -p $PRD{/surface,/connectivity} $PRD/$SUBJ_ID/{surface,connectivity}

# build cortical surface and region mapping
T1=$PRD/data/T1/T1.nii.gz

gen convert_to_niigz $T1 $PRD/data/T1/
gen fs_recon_all $FS/$SUBJ_ID $T1 $SUBJ_ID

hemi=lh
gen ascii_surface $PRD/surface/${hemi}_vertices_high.txt $hemi
gen remesh $PRD/surface/${hemi}_vertices_low.txt $hemi
gen make_region_mapping $PRD/surface/${hemi}_region_mapping_low.txt $hemi

hemi=rh
gen ascii_surface $PRD/surface/${hemi}_vertices_high.txt $hemi
gen remesh $PRD/surface/${hemi}_vertices_low.txt $hemi
gen make_region_mapping $PRD/surface/${hemi}_region_mapping_low.txt $hemi

gen unify_region_mappings $PRD/$SUBJ_ID/surface/region_mapping.txt

gen finalize_surface_data_files $PRD/SUBJ_ID/surface.zip

# extract subcortical surfaces 
if [ ! -f $PRD/surface/subcortical/aseg_058_vert.txt ]
then
    echo "generating subcortical surfaces"
    ./aseg2srf -s $SUBJ_ID
    mkdir -p $PRD/surface/subcortical
    cp $FS/$SUBJ_ID/ascii/* $PRD/surface/subcortical
    python list_subcortical.py
fi

# convert DWI files
# if single acquisition  with reversed directions
function mrchoose () {
    choice=$1
    shift
    $@ << EOF
$choice
EOF
}

if [ "$topup" = "reversed" ]
then
    echo "use topup and eddy from fsl to correct EPI distortions"

    if [ ! -f $PRD/connectivity/dwi_1.nii.gz ]
    then
        mrchoose 0 mrconvert $PRD/data/DWI/ $PRD/connectivity/dwi_1.nii.gz
        mrchoose 0 mrinfo $PRD/data/DWI/ -export_grad_fsl $PRD/connectivity/bvecs_1 $PRD/connectivity/bvals_1
        mrchoose 1 mrconvert $PRD/data/DWI/ $PRD/connectivity/dwi_2.nii.gz
        mrchoose 1 mrinfo $PRD/data/DWI/ -export_grad_fsl $PRD/connectivity/bvecs_2 $PRD/connectivity/bvals_2
        mrconvert $PRD/connectivity/dwi_1.nii.gz $PRD/connectivity/dwi_1.mif -fslgrad $PRD/connectivity/bvecs_1 $PRD/connectivity/bvals_1
        mrconvert $PRD/connectivity/dwi_2.nii.gz $PRD/connectivity/dwi_2.mif -fslgrad $PRD/connectivity/bvecs_2 $PRD/connectivity/bvals_2
    fi
    if [ ! -f $PRD/connectivity/dwi.mif ]
    then
        revpe_dwicombine $PRD/connectivity/dwi_1.mif $PRD/connectivity/dwi_2.mif 1 $PRD/connectivity/dwi.mif
    fi
else
    # mrconvert
    if [ ! -f $PRD/connectivity/dwi.nii.gz ]
    then
        if [ -f $PRD/data/DWI/*.nii.gz ]
        then
            echo "use already existing nii files"
            ls $PRD/data/DWI/ | grep '.nii.gz$' | xargs -I {} cp $PRD/data/DWI/{} $PRD/connectivity/dwi.nii.gz
            cp $PRD/data/DWI/bvecs $PRD/connectivity/bvecs
            cp $PRD/data/DWI/bvals $PRD/connectivity/bvals
        else
            echo "generate dwi.nii.gz"
            mrconvert $PRD/data/DWI/ $PRD/connectivity/dwi.nii.gz
            echo "extract bvecs and bvals"
            mrinfo $PRD/data/DWI/ -export_grad_fsl $PRD/connectivity/bvecs $PRD/connectivity/bvals
        fi
    fi
    # eddy correct
    if [ ! -f $PRD/connectivity/dwi.mif ]
    then
        if [ "$topup" =  "eddy_correct" ]
        then
            echo "eddy correct data"
            "$FSL"eddy_correct $PRD/connectivity/dwi.nii.gz $PRD/connectivity/dwi_eddy_corrected.nii.gz 0
            mrconvert $PRD/connectivity/dwi_eddy_corrected.nii.gz $PRD/connectivity/dwi.mif -fslgrad $PRD/connectivity/bvecs $PRD/connectivity/bvals
        else
            mrconvert $PRD/connectivity/dwi.nii.gz $PRD/connectivity/dwi.mif -fslgrad $PRD/connectivity/bvecs $PRD/connectivity/bvals
        fi
    fi
fi

# make brain mask
if [ ! -f $PRD/connectivity/mask.mif ]
then
    dwi2mask $PRD/connectivity/dwi.mif $PRD/connectivity/mask.mif
fi

# extract b=0
if [ ! -f $PRD/connectivity/lowb.nii.gz ]
then
    dwiextract $PRD/connectivity/dwi.mif $PRD/connectivity/lowb.mif -bzero
    mrconvert $PRD/connectivity/lowb.mif $PRD/connectivity/lowb.nii.gz 
fi

# FLIRT registration

# make t1 & parcseg in ras orientation, nifti format
for im in T1 aparc+aseg; do
	mri_convert --in_type mgz --out_type nii --out_orientation RAS \
		$FS/$SUBJ_ID/mri/${im}.mgz \
		$PRD/connectivity/${im}.nii.gz
done

pushd $PRD/connectivity

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


# response function estimation
dwi2response dwi.mif response.txt -mask mask.mif 

# fibre orientation distribution estimation if [ ! -f CSD$lmax.mif ]
dwi2fod dwi.mif response.txt CSD$lmax.mif -lmax $lmax -mask mask.mif

# prepare file for act if [ "$act" = "yes" ] && [ ! -f act.mif ]
act_anat_prepare_fsl T1_2_diff.nii.gz act.mif

# tractography
if [ ! -f whole_brain.tck ] ; then
	if [ "$act" = "yes" ] ; then
		5tt2gmwmi act.mif gmwmi_mask.mif
		tckgen_args="-seed_gmwmi gmwmi_mask.mif -act act.mif"
	else
		tckgen_args="-algorithm iFOD2 -seed_image aparcaseg_2_diff.nii.gz -mask mask.mif"
	fi
	tckgen_args="-unidirectional -num $number_tracks -maxlength 250 -step 0.5 $tck_args"
	tckgen CSD$lmax.mif whole_brain.tck $tckgen_args
fi

# post process with sift
if [ "$sift" = "yes" ] && [ ! -f whole_brain_post.tck ]
then
	echo "using sift"
	tcksift_args="-term_number $(( number_tracks/2 ))"
	if [ "$act" = "yes" ] ; then
		tcksift_args="-act act.mif $tcksift_args" 
	fi
	tcksift whole_brain.tck CSD"$lmax".mif whole_brain_post.tck $tcksift_args
elif [ ! -f whole_brain_post.tck ] ; then
	echo "not using SIFT"
	ln -s whole_brain.tck whole_brain_post.tck
fi

popd # $PRD/connectivity

# now compute connectivity and length matrix without subdivisions
if [ ! -f $PRD/connectivity/aparcaseg_2_diff.mif ]
then
    echo " compute labels"
    labelconfig $PRD/connectivity/aparcaseg_2_diff.nii.gz fs_region.txt $PRD/connectivity/aparcaseg_2_diff.mif -lut_freesurfer $FREESURFER_HOME/FreeSurferColorLUT.txt
fi
if [ ! -f $PRD/connectivity/weights.csv ]
then
    echo "compute connectivity matrix"
    tck2connectome $PRD/connectivity/whole_brain_post.tck $PRD/connectivity/aparcaseg_2_diff.mif $PRD/connectivity/weights.csv -assignment_radial_search 2
    tck2connectome $PRD/connectivity/whole_brain_post.tck $PRD/connectivity/aparcaseg_2_diff.mif $PRD/connectivity/tract_lengths.csv -metric meanlength -zero_diagonal -assignment_radial_search 2 
fi

# Compute other files
# we do not compute hemisphere
# subcortical is already done
cp cortical.txt $PRD/$SUBJ_ID/connectivity/cortical.txt

# compute centers, areas and orientations
if [ ! -f $PRD/$SUBJ_ID/connectivity/weights.txt ]
then
    echo " generate useful files for TVB"
    python compute_connectivity_files.py
fi

# zip to put in final format
pushd . > /dev/null
cd $PRD/$SUBJ_ID/connectivity > /dev/null
zip $PRD/$SUBJ_ID/connectivity.zip areas.txt average_orientations.txt weights.txt tract_lengths.txt cortical.txt centres.txt -q
popd > /dev/null 

# compute sub parcellations connectivity if asked
if [ -n "$K_list" ]
then
    for K in $K_list
    do
        export curr_K=$(( 2**K ))
        mkdir -p $PRD/$SUBJ_ID/connectivity_"$curr_K"
        if [ -n "$matlab" ]  
        then
            if [ ! -f $PRD/connectivity/aparcaseg_2_diff_"$curr_K".nii.gz ]
            then
            $matlab -r "run subparcel.m; quit;" -nodesktop -nodisplay 
            gzip $PRD/connectivity/aparcaseg_2_diff_"$curr_K".nii
            fi
        else
            if [ ! -f $PRD/connectivity/aparcaseg_2_diff_"$curr_K".nii.gz ]
            then
            sh subparcel/distrib/run_subparcel.sh $MCR  
            gzip $PRD/connectivity/aparcaseg_2_diff_"$curr_K".nii
            fi
        fi
        if [ ! -f $PRD/connectivity/aparcaseg_2_diff_"$curr_K".mif ]
        then
            labelconfig $PRD/connectivity/aparcaseg_2_diff_"$curr_K".nii.gz $PRD/connectivity/corr_mat_"$curr_K".txt $PRD/connectivity/aparcaseg_2_diff_"$curr_K".mif  -lut_basic $PRD/connectivity/corr_mat_"$curr_K".txt
        fi
        if [ ! -f $PRD/connectivity/weights_$curr_K.csv ]
        then
            echo "compute connectivity sub matrix using act"
            tck2connectome $PRD/connectivity/whole_brain_post.tck $PRD/connectivity/aparcaseg_2_diff_"$curr_K".mif $PRD/connectivity/weights_"$curr_K".csv -assignment_radial_search 2
            tck2connectome  $PRD/connectivity/whole_brain_post.tck $PRD/connectivity/aparcaseg_2_diff_"$curr_K".mif $PRD/connectivity/tract_lengths_"$curr_K".csv -metric meanlength -assignment_radial_search 2 -zero_diagonal 
        fi
        if [ ! -f $PRD/$SUBJ_ID/connectivity_"$curr_K"/weights.txt ]
        then
            echo "generate files for TVB subparcellations"
            python compute_connectivity_sub.py $PRD/connectivity/weights_"$curr_K".csv $PRD/connectivity/tract_lengths_"$curr_K".csv $PRD/$SUBJ_ID/connectivity_"$curr_K"/weights.txt $PRD/$SUBJ_ID/connectivity_"$curr_K"/tract_lengths.txt
        fi
        pushd . > /dev/null
        cd $PRD/$SUBJ_ID/connectivity_"$curr_K" > /dev/null
        zip $PRD/$SUBJ_ID/connectivity_"$curr_K".zip weights.txt tract_lengths.txt centres.txt average_orientations.txt -q 
        popd > /dev/null
    done
fi

######################## compute MEG and EEG forward projection matrices
# make BEM surfaces
if [ ! -h ${FS}/${SUBJ_ID}/bem/inner_skull.surf ]
then
    echo "generating bem surfaces"
    mne_watershed_bem --subject ${SUBJ_ID}
    ln -s ${FS}/${SUBJ_ID}/bem/watershed/${SUBJ_ID}_inner_skull_surface ${FS}/${SUBJ_ID}/bem/inner_skull.surf
    ln -s ${FS}/${SUBJ_ID}/bem/watershed/${SUBJ_ID}_outer_skin_surface  ${FS}/${SUBJ_ID}/bem/outer_skin.surf
    ln -s ${FS}/${SUBJ_ID}/bem/watershed/${SUBJ_ID}_outer_skull_surface ${FS}/${SUBJ_ID}/bem/outer_skull.surf
fi

# export to ascii
if [ ! -f ${FS}/${SUBJ_ID}/bem/inner_skull.asc ]
then
    echo "importing bem surface from freesurfer"
    mris_convert $FS/$SUBJ_ID/bem/inner_skull.surf $FS/$SUBJ_ID/bem/inner_skull.asc
    mris_convert $FS/$SUBJ_ID/bem/outer_skull.surf $FS/$SUBJ_ID/bem/outer_skull.asc
    mris_convert $FS/$SUBJ_ID/bem/outer_skin.surf $FS/$SUBJ_ID/bem/outer_skin.asc
fi

# triangles and vertices bem
if [ ! -f $PRD/$SUBJ_ID/surface/inner_skull_vertices.txt ]
then
    echo "extracting bem vertices and triangles"
    python extract_bem.py inner_skull 
    python extract_bem.py outer_skull 
    python extract_bem.py outer_skin 
fi

if [ ! -f ${FS}/${SUBJ_ID}/bem/${SUBJ_ID}-head.fif ]
then
    echo "generating head bem"
    mkheadsurf -s $SUBJ_ID
    mne_surf2bem --surf ${FS}/${SUBJ_ID}/surf/lh.seghead --id 4 --check --fif ${FS}/${SUBJ_ID}/bem/${SUBJ_ID}-head.fif 
fi

if [ -n "$DISPLAY" ] && [ "$CHECK" = "yes" ]
then
    echo "check bem surfaces"
    freeview -v ${FS}/${SUBJ_ID}/mri/T1.mgz -f ${FS}/${SUBJ_ID}/bem/inner_skull.surf:color=yellow:edgecolor=yellow ${FS}/${SUBJ_ID}/bem/outer_skull.surf:color=blue:edgecolor=blue ${FS}/${SUBJ_ID}/bem/outer_skin.surf:color=red:edgecolor=red
fi

# Setup BEM
if [ ! -f ${FS}/${SUBJ_ID}/bem/*-bem.fif ]
then
    worked=0
    outershift=0
    while [ "$worked" == 0 ]
    do
        echo "try generate forward model with 0 shift"
        worked=1
        mne_setup_forward_model --subject ${SUBJ_ID} --surf --ico 4 --outershift $outershift || worked=0 
        if [ "$worked" == 0 ]
        then
            echo "try generate foward model with 1 shift"
            worked=1
            mne_setup_forward_model --subject ${SUBJ_ID} --surf --ico 4 --outershift 1 || worked=0 
        fi
        if [ "$worked" == 0 ] && [ "$CHECK" = "yes" ]
        then
            echo 'you can try using a different shifting value for outer skull, please enter a value in mm'
            read outershift;
            echo $outershift
        elif [ "$worked" == 0 ]
        then
            echo "bem did not worked"
            worked=1
        elif [ "$worked" == 1 ]
        then
            echo "success!"
        fi
    done
fi

