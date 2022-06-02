source common.sh

clearStore

cd "$TEST_ROOT"

test_fetch_file () {
    echo foo > test_input

    input_hash="$(nix hash path test_input)"

    nix eval --impure --file - <<EOF
    let
        tree = builtins.fetchTree { type = "file"; url = "file://$PWD/test_input"; };
    in
    assert (tree.narHash == "$input_hash");
    tree
EOF
}

# Make sure that `http(s)` and `file` flake inputs are properly extracted when
# they should be, and treated as opaque files when they should be
test_file_flake_input () {
    rm -fr "$TEST_ROOT/testFlake";
    mkdir "$TEST_ROOT/testFlake";
    pushd testFlake

    mkdir inputs
    echo foo > inputs/test_input_file
    tar cfa test_input.tar.gz inputs
    cp test_input.tar.gz test_input_no_ext
    input_tarball_hash="$(nix hash path test_input.tar.gz)"
    input_directory_hash="$(nix hash path inputs)"

    cat <<EOF > flake.nix
    {
        inputs.no_ext_default_no_unpack = {
            url = "file://$PWD/test_input_no_ext";
            flake = false;
        };
        inputs.no_ext_explicit_unpack = {
            url = "tarball+file://$PWD/test_input_no_ext";
            flake = false;
        };
        inputs.tarball_default_unpack = {
            url = "file://$PWD/test_input.tar.gz";
            flake = false;
        };
        inputs.tarball_explicit_no_unpack = {
            url = "file+file://$PWD/test_input.tar.gz";
            flake = false;
        };
        outputs = { ... }: {};
    }
EOF

    nix flake update
    nix eval --file - <<EOF
    with (builtins.fromJSON (builtins.readFile ./flake.lock));

    # Url inputs whose extension doesn’t match a know archive format should
    # not be unpacked by default
    assert (nodes.no_ext_default_no_unpack.locked.type == "file");
    assert (nodes.no_ext_default_no_unpack.locked.unpack or false == false);
    assert (nodes.no_ext_default_no_unpack.locked.narHash == "$input_tarball_hash");

    # For backwards compatibility, flake inputs that correspond to the
    # old 'tarball' fetcher should still have their type set to 'tarball'
    assert (nodes.tarball_default_unpack.locked.type == "tarball");
    # Unless explicitely specified, the 'unpack' parameter shouldn’t appear here
    # because that would break older Nix versions
    assert (!nodes.tarball_default_unpack.locked ? unpack);
    assert (nodes.tarball_default_unpack.locked.narHash == "$input_directory_hash");

    # Explicitely passing the unpack parameter should enforce the desired behavior
    assert (nodes.no_ext_explicit_unpack.locked.narHash == nodes.tarball_default_unpack.locked.narHash);
    assert (nodes.tarball_explicit_no_unpack.locked.narHash == nodes.no_ext_default_no_unpack.locked.narHash);
    true
EOF
    popd

    [[ -z "${NIX_DAEMON_PACKAGE}" ]] && return 0

    # Ensure that a lockfile generated by the current Nix for tarball inputs
    # can still be read by an older Nix

    cat <<EOF > flake.nix
    {
        inputs.tarball = {
            url = "file://$PWD/test_input.tar.gz";
            flake = false;
        };
        outputs = { self, tarball }: {
            foo = builtins.readFile "${tarball}/test_input_file";
        };
    }
    nix flake update

    clearStore
    "$NIX_DAEMON_PACKAGE/bin/nix" eval .#foo
EOF
}

test_fetch_file
test_file_flake_input
