module supra_utils::merkle_tree {
    use std::vector;
    use std::error;
    use aptos_std::aptos_hash::keccak256;
    #[test_only]
    use aptos_std::debug;

    /// bytes length is not same to compare
    const EINVALID_BYTES_LENGTH: u64 = 500;
    /// bytes length is 0
    const EEMPTY_BYTES: u64 = 501;
    /// The index into the vector is out of bounds
    const EINDEX_OUT_OF_BOUNDS: u64 = 502;
    /// Multiproof merkle verification failed
    const EINVALID_MERKLE_PROOF: u64 = 503;

    public fun generate_merkle_tree(leaf_hashes: vector<vector<u8>>) : vector<u8> {
        let len_leaf_hashes = vector::length(&leaf_hashes);
        if (len_leaf_hashes != 1) {
            let levelHash = vector::empty<vector<u8>>();
            let bytes1: vector<u8>;
            let bytes2: vector<u8>;
            vector :: reverse(&mut leaf_hashes);
            while (vector::length(&leaf_hashes) != 0){
                bytes1 = vector::pop_back(&mut leaf_hashes);
                if(!vector::is_empty(&leaf_hashes))
                    bytes2 = vector::pop_back(&mut leaf_hashes)
                else
                    bytes2 = vector::empty<u8>();
                vector::push_back(&mut levelHash, get_immediate_root_hash(&bytes1,&bytes2));
            };
            return generate_merkle_tree(levelHash)
        };
        return vector::pop_back(&mut leaf_hashes)
    }


    /// function that Verify merkle tree proof
    public fun verify_merkle_tree(leaf_hash: vector<u8>, proof: vector<vector<u8>>, root: vector<u8>): bool {
        let i = 0;
        let proof_len = vector::length(&proof);
        while (i < proof_len) {
            let item_proof = *vector::borrow(&proof, i);
            let item_proof_hash = if (compare_vector_greater_than(&leaf_hash, &item_proof) == 1) {
                vector::append(&mut item_proof, leaf_hash);
                keccak256(item_proof)
            } else {
                vector::append(&mut leaf_hash, item_proof);
                keccak256(leaf_hash)
            };
            leaf_hash = item_proof_hash;
            i = i + 1;
        };
        leaf_hash == root
    }

    /// Retrieves the next element from a vector at a given position and increments the position.
    fun next_element<T: copy>(pos: &mut u64, data: &vector<T>): T {
        assert!(vector::length(data) > *pos, error::out_of_range(EINDEX_OUT_OF_BOUNDS));
        let h = *vector::borrow(data, *pos);
        *pos = *pos + 1;
        h
    }

    /// ensure multi proof merkle all lengths are valid
    public fun ensure_multileaf_merkle_proof_lengths<T: drop>(proof: vector<vector<u8>>, flags: vector<bool>, leaves: vector<T>) {
        // it should be (leaves_len + proofs_len == flags_len + 1)
        assert!(
            (vector::length(&leaves) + vector::length(&proof)) == (vector::length(&flags) + 1),
            error::invalid_state(EINVALID_MERKLE_PROOF)
        );
    }

    /// Function that verify Multileaf merkle proof
    public fun is_valid_multileaf_merkle_proof(
        proofs: vector<vector<u8>>,
        flags: vector<bool>,
        leaves: vector<vector<u8>>,
        root: vector<u8>
    ): bool {
        ensure_multileaf_merkle_proof_lengths(proofs, flags, leaves);

        let leaf_pos = 0;
        let hash_pos = 0;
        let proof_pos = 0;
        let hashes = vector[];

        let leave_len = vector::length(&leaves);
        vector::for_each(flags, |flag| {
            let a = if (leaf_pos < leave_len) {
                next_element(&mut leaf_pos, &leaves)
            } else {
                next_element(&mut hash_pos, &hashes)
            };

            let b = if (flag) {
                if (leaf_pos < leave_len) {
                    next_element(&mut leaf_pos, &leaves)
                } else {
                    next_element(&mut hash_pos, &hashes)
                }
            } else {
                next_element(&mut proof_pos, &proofs)
            };

            let hash_pair = if (compare_vector_greater_than(&a, &b) == 1) {
                vector::append(&mut b, a);
                keccak256(b)
            } else {
                vector::append(&mut a, b);
                keccak256(a)
            };

            vector::push_back(&mut hashes, hash_pair);
        });

        let calculated_root = if (vector::length(&flags) > 0) {
            assert!(proof_pos == vector::length(&proofs), EINVALID_MERKLE_PROOF);
            vector::pop_back(&mut hashes)
        } else if (leave_len > 0) {
            *vector::borrow(&leaves, 0)
        } else {
            *vector::borrow(&proofs, 0)
        };
        root == calculated_root
    }

    public fun get_immediate_root_hash(bytes1: &vector<u8>, bytes2: &vector<u8>): vector<u8> {
        if (vector::is_empty(bytes2)){
            // return *bytes1
            bytes2 = bytes1;
        };
        let immediate_hash = vector::empty<u8>();
        if (compare_vector_greater_than(bytes1, bytes2) == 2) {
            vector::append(&mut immediate_hash, *bytes1);
            vector::append(&mut immediate_hash, *bytes2);
        } else {
            vector::append(&mut immediate_hash, *bytes2);
            vector::append(&mut immediate_hash, *bytes1);
        };
        return keccak256(immediate_hash)

    }


    /// Compate two vector and which of this is greater than, [bytes1 = bytes2] => 0, [bytes1 > bytes2] => 1, [bytes2 > bytes1] => 2
    public fun compare_vector_greater_than(bytes1: &vector<u8>, bytes2: &vector<u8>): u8 {
        assert!(vector::length(bytes1) != 0, EEMPTY_BYTES);
        assert!(vector::length(bytes1) == vector::length(bytes2), EINVALID_BYTES_LENGTH);
        let i = 0;
        let length = vector::length(bytes1);
        let _status = 0; // default value is 0
        loop {
            let a = *vector::borrow(bytes1, i);
            let b = *vector::borrow(bytes2, i);
            if (a > b) {
                _status = 1;
                break
            } else if (a < b) {
                _status = 2;
                break
            };
            i = i + 1;
            if (i >= length) { break }; // break the loop
        };
        _status
    }

    #[test]
    #[expected_failure(abort_code = EEMPTY_BYTES, location = Self)]
    public fun test_compare_vector_two_empty_bytes() {
        let bytes1 = vector::empty<u8>();
        let bytes2 = vector::empty<u8>();
        let result = compare_vector_greater_than(&bytes1, &bytes2);
        assert!(result == 0, 0);
    }

    #[test]
    fun merkle_tree_creation_even_leaves() {
        let leaves: vector<vector<u8>> = vector[x"011b4d03dd8c01f1049143cf9c4c817e4b167f1d1b83e5c6f0f10d89ba1e7bce",
                                                x"6c31fc15422ebad28aaf9089c306702f67540b53c7eea8b7d2941044b027100f",
                                                x"859f11b75569a4eb0496c5138fd42cc52aee8cf5c4e7cfafe58c92b2ed138e04",
                                                x"d4c69e49e83a6047f46e42b2d053a1f0c6e70ea42862e5ef4ad66b3666c5e2af",
                                                x"d2ed8d75f801ae8a206c07ff9b104f0e005238dcd1cbaf844fd9f40d63174c56",
                                                x"fe07a98784cd1850eae35ede546d7028e6bf9569108995fc410868db775e5e6a",
                                                x"c3751ea2572cb6b4f061af1127a67eaded2cfc191f2a18d69000bbe2e98b680a",
                                                x"ea2e640cf9cf85178466ebb2f721ea6b3ec88def0a8c3d3f7d31e775eed05347",
                                                ];

        let root: vector<u8> = x"16257cfad4a3b033c2bf277b630fdeebd2f7796edaffff01282aa19be32c648d";
        let generated_root:vector<u8> = generate_merkle_tree(leaves);
        assert!(root == generated_root,404);
        debug::print<vector<u8>>(&generated_root);
    }

    #[test]
    fun merkle_tree_creation_odd_leaves() {
        let leaves: vector<vector<u8>> = vector[x"011b4d03dd8c01f1049143cf9c4c817e4b167f1d1b83e5c6f0f10d89ba1e7bce",
            x"6c31fc15422ebad28aaf9089c306702f67540b53c7eea8b7d2941044b027100f",
            x"859f11b75569a4eb0496c5138fd42cc52aee8cf5c4e7cfafe58c92b2ed138e04",
            x"d4c69e49e83a6047f46e42b2d053a1f0c6e70ea42862e5ef4ad66b3666c5e2af",
            x"d2ed8d75f801ae8a206c07ff9b104f0e005238dcd1cbaf844fd9f40d63174c56",
            x"fe07a98784cd1850eae35ede546d7028e6bf9569108995fc410868db775e5e6a",
            x"c3751ea2572cb6b4f061af1127a67eaded2cfc191f2a18d69000bbe2e98b680a",
        ];

        let root: vector<u8> = x"0e716d0b4f0aa1fc785dc834bbedbab132c28b4cf7134aadb050d43b39e8bc8b";
        let generated_root:vector<u8> = generate_merkle_tree(leaves);
        assert!(root == generated_root,404);
        debug::print<vector<u8>>(&generated_root);
    }
}