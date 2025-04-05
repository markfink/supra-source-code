module supra_addr::supra_util {
    use std::bcs;
    use std::error;
    use std::option;
    use std::signer;
    use std::vector;

    use aptos_std::bls12381;
    use aptos_std::aptos_hash::keccak256;

    use supra_framework::object;

    friend supra_addr::supra_vrf; // added supra_vrf in friend list, so free_node module can access

    /// Bytes length should be 32
    const EBYTES_LENGTH: u64 = 1;
    /// Only Authorized users can access it
    const EUNAUTHORIZED_ACCESS: u64 = 2;

    public(friend) fun message_hash(
        nonce: u64,
        instance_id: u64,
        caller_address: address,
        rng_count: u8,
        client_seed: u64
    ): vector<u8> {
        let result_hash: vector<u8> = vector[];
        vector::append(&mut result_hash, bcs::to_bytes(&nonce));
        vector::append(&mut result_hash, bcs::to_bytes(&instance_id));
        vector::append(&mut result_hash, bcs::to_bytes(&caller_address));
        vector::append(&mut result_hash, bcs::to_bytes(&rng_count));
        vector::append(&mut result_hash, bcs::to_bytes(&client_seed));
        keccak256(result_hash)
    }

    /// Internal - Internal function that calls bls12381 to verify the signature
    public(friend) fun verify_signature(public_key: vector<u8>, msg: vector<u8>, signature: vector<u8>): bool {
        bls12381::verify_normal_signature(
            &bls12381::signature_from_bytes(signature),
            &option::extract(&mut bls12381::public_key_from_bytes(public_key)),
            msg
        )
    }

    /// Internal function uses to generate random number based on seed and count
    public(friend) fun get_random_numbers(signature: vector<u8>, rng_count: u8, client_seed: u64): vector<u256> {
        let random_numbers: vector<u256> = vector::empty<u256>();
        let client_seed = bcs::to_bytes(&client_seed);
        while (rng_count != 0) {
            let random_number_seed: vector<u8> = signature;
            vector::push_back(&mut random_number_seed, rng_count);
            vector::append(&mut random_number_seed, client_seed);

            let seed_keccak256: vector<u8> = keccak256(random_number_seed);

            vector::push_back(&mut random_numbers, bytes_to_u256(&seed_keccak256));
            rng_count = rng_count - 1;
        };
        random_numbers
    }

    /// this function converts 32 bytes into an u256 number
    fun bytes_to_u256(bytes: &vector<u8>): u256 {
        assert!(vector::length(bytes) == 32, EBYTES_LENGTH);
        let value: u256 = 0;
        let i: u64 = 0;
        while (i < 32) {
            let tmp = (*vector::borrow(bytes, i) as u256);
            value = value << 8u8;
            value = value | tmp;
            i = i + 1;
        };
        return value
    }

    /// Ensures that the specified index belongs to the given owner.
    public fun ensure_object_owner<T: key>(object: object::Object<T>, caller: &signer) {
        assert!(
            object::is_owner(object, signer::address_of(caller)),
            error::permission_denied(EUNAUTHORIZED_ACCESS)
        );
    }
}
