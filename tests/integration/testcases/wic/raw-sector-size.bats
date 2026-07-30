bats_load_library 'bats/bats-support/load.bash'
bats_load_library 'bats/bats-assert/load.bash'
bats_load_library 'bats/bats-file/load.bash'
load '../lib/common.bash'

RSS_SYNTH_4K=rss_synth_4k.img
RSS_SYNTH_512=rss_synth_512.img
# Measured empirically against the intel-corei7-64 Common Torizon fixture:
# sysroot + this slack lands the 4Kn image's free root space just inside
# combine's 98%-full growth path for the "hello" bundle, without landing on
# the free-space-exactly-zero case (a ZeroDivisionError in combine.py itself).
RSS_SLACK_4K_KB=132400
# No ratio target for the 512 case (this only proves the synthesis helper
# itself is sector-size-agnostic) - a generous fixed margin is fine here.
RSS_SLACK_512_KB=204800

# Builds a synthetic raw disk at $1, at sector size $2 (512 or 4096), sized
# to at least $3 KB, and copies the already-unpacked $DEFAULT_WIC_IMAGE
# sysroot into a fresh "otaroot" ext4 partition on it. Mirrors
# write_rootfs_to_raw_image()'s own primitives (mkfs ext4, set-label
# otaroot, copy-in) so the disk this test builds is exactly what the code
# under test later expects to open.
build-synth-raw-image() {
    local out="$1"
    local sector="$2"
    local size_kb="$3"
    # Round the byte size up to a whole sector - size_kb*1024 is not
    # guaranteed to be a sector multiple (sysroot_kb comes from "du -s",
    # not a fixed constant), and guestfish/qemu expect a sector-aligned
    # disk. Mirrors grow_last_partition()'s own rounding (deploy.py:337).
    local total_bytes=$(( size_kb * 1024 ))
    total_bytes=$(( (total_bytes + sector - 1) / sector * sector ))
    local total_sectors=$(( total_bytes / sector ))
    # 33 LBAs (512-byte) reserved for the GPT backup header, converted to
    # this disk's own sector size - grow_last_partition's own calculation
    # (deploy.py:355).
    local gpt_tail=$(( (33 * 512 + sector - 1) / sector ))
    local end_sector=$(( total_sectors - 1 - gpt_tail ))
    local blocksize_opt=""
    [ "$sector" = "4096" ] && blocksize_opt="--blocksize=4096"

    # copy-in copies its source in as a subdirectory of the destination, so
    # (unlike copy-out) it cannot flatten /storage/sysroot's own contents to
    # "/" in one call - copy each top-level entry individually instead,
    # exactly as write_rootfs_to_raw_image() does with gfs.copy_in(), skipping
    # "lost+found" the same way.
    local copy_in_ops=""
    local entry
    while IFS= read -r entry; do
        [ "$entry" = "lost+found" ] && continue
        copy_in_ops+=" copy-in /storage/sysroot/$entry / :"
    done < <(torizoncore-builder-shell "ls /storage/sysroot")

    rm -f "$out"
    torizoncore-builder-shell "truncate -s $total_bytes $out"
    torizoncore-builder-shell "guestfish $blocksize_opt -a $out -- \
        run : \
        part-init /dev/sda gpt : \
        part-add /dev/sda primary 2048 $end_sector : \
        mkfs ext4 /dev/sda1 : \
        set-label /dev/sda1 otaroot : \
        mount /dev/sda1 / : \
        $copy_in_ops \
        umount /"
}

setup_file() {
    torizoncore-builder-clean-storage
    torizoncore-builder images --remove-storage unpack $DEFAULT_WIC_IMAGE

    # Size the 4Kn disk tightly to the actual unpacked content, measured
    # here rather than assumed, so the margin does not silently drift if the
    # upstream fixture's size changes.
    local sysroot_kb
    sysroot_kb=$(torizoncore-builder-shell "du -s /storage/sysroot" | cut -f1)

    build-synth-raw-image "$RSS_SYNTH_4K" 4096 $(( sysroot_kb + RSS_SLACK_4K_KB ))
    build-synth-raw-image "$RSS_SYNTH_512" 512 $(( sysroot_kb + RSS_SLACK_512_KB ))
}

teardown_file() {
    rm -f "$RSS_SYNTH_4K" "$RSS_SYNTH_512"
}

@test "raw sector size: images unpack from a 4Kn raw image" {
    torizoncore-builder-clean-storage

    run torizoncore-builder images --remove-storage unpack --raw-sector-size 4096 $RSS_SYNTH_4K
    assert_success
    assert_output --partial "Unpacked OSTree from WIC/raw image"
}

@test "raw sector size: deploy changes to a 4Kn raw image" {
    rm -rf rss_deploy_out.img

    torizoncore-builder-clean-storage
    torizoncore-builder images --remove-storage unpack --raw-sector-size 4096 $RSS_SYNTH_4K
    torizoncore-builder union --changes-directory $SAMPLES_DIR/changes branch1

    run torizoncore-builder deploy --base-raw $RSS_SYNTH_4K --raw-sector-size 4096 \
                                   --output-raw rss_deploy_out.img branch1
    assert_success
    assert_output --partial "created successfully!"

    rm -rf rss_deploy_out.img
}

@test "raw sector size: combine grows a 4Kn image past the 98% ratio" {
    local ci_dockerhub_login="$(ci-dockerhub-login-flag)"

    local compose='rss_docker-compose.yml'
    cp "$SAMPLES_DIR/compose/hello/docker-compose.yml" "$compose"

    rm -rf rss_bundle rss_combine_out.img
    run torizoncore-builder bundle --bundle-directory rss_bundle "$compose" \
        ${ci_dockerhub_login:+"--login" "${CI_DOCKER_HUB_PULL_USER}" "${CI_DOCKER_HUB_PULL_PASSWORD}"}
    assert_success

    if [ "${ci_dockerhub_login}" = "1" ]; then
        assert_output --partial "Attempting to log in to"
    fi

    run torizoncore-builder combine --bundle-directory rss_bundle --force --raw-sector-size 4096 \
                                    $RSS_SYNTH_4K rss_combine_out.img
    assert_success
    assert_output --partial "Output disk will be increased"

    rm -rf "$compose" rss_bundle rss_combine_out.img
}

@test "raw sector size: images unpack from a 512 raw image (regression guard on the new synthesis helper)" {
    torizoncore-builder-clean-storage

    run torizoncore-builder images --remove-storage unpack $RSS_SYNTH_512
    assert_success
    assert_output --partial "Unpacked OSTree from WIC/raw image"
}
