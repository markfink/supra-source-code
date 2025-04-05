module supra_utils::utils {
    use std::error;
    use std::vector;
    use std::option;
    use std::signer;
    use supra_framework::object;
    use aptos_std::bls12381;

    /// Undefined expression
    const EUNDEFIND_EXP: u64 = 1;
    /// Only Authorized users can access it
    const EUNAUTHORIZED_ACCESS: u64 = 2;
    /// Bits are too high to get the max value
    const EBITS_NOT_SUPPORTED: u64 = 3;


    /// Max value of u256
    const MAX_U256: u256 = 115792089237316195423570985008687907853269984665640564039457584007913129639935;


    /// unstable append of second vector into first vector
    public fun destructive_reverse_append<Element: drop>(first: &mut vector<Element>, second: vector<Element>) {
        while (!vector::is_empty(&second)) {
            vector::push_back(first, vector::pop_back(&mut second));
        }
    }

    /// Flatten and concatenate the vectors
    public fun vector_flatten_concat<Element: copy + drop>(lhs: &mut vector<Element>, other: vector<vector<Element>>) {
        let i = 0;
        let length = vector::length(&other);
        while (i < length) {
            let bytes = vector::borrow(&other, i);
            vector::append(lhs, *bytes);
            i = i + 1;
        };
    }

    /// function that calls bls12381 to verify the signature
    public fun verify_signature(public_key: vector<u8>, msg: vector<u8>, signature: vector<u8>): bool {
        bls12381::verify_normal_signature(
            &bls12381::signature_from_bytes(signature),
            &option::extract(&mut bls12381::public_key_from_bytes(public_key)),
            msg
        )
    }

    /// Calculates the power of a base raised to an exponent. The result of `base` raised to the power of `exponent`
    public fun calculate_power(base: u128, exponent: u16): u256 {
        let result: u256 = 1;
        let base: u256 = (base as u256);
        assert!((base | (exponent as u256)) != 0, error::internal(EUNDEFIND_EXP));
        if (base == 0) { return 0 };
        while (exponent != 0) {
            if ((exponent & 0x1) == 1) { result = result * base; };
            base = base * base;
            exponent = (exponent >> 1);
        };
        result
    }

    /// Ensures that the specified index belongs to the given owner.
    public fun ensure_object_owner<T: key>(object: object::Object<T>, caller: &signer) {
        assert!(
            object::is_owner(object, signer::address_of(caller)),
            error::permission_denied(EUNAUTHORIZED_ACCESS)
        );
    }

    public fun num_bits(num: u256):u16 {
        let bits:u16 = 0;
        while (num > 254){
            bits = bits + 8;
            num = num >> 8;
        };
        while (num != 0) {
            bits = bits + 1;
            num = num >> 1;
        };
        return bits
    }

    public fun max_x_bits(x: u16): u256 {
        assert!(x < 257, error::invalid_state(EBITS_NOT_SUPPORTED));
        if (x == 256_u16) return MAX_U256;
        let num = 1;
        num = num << (x as u8);
        num = num - 1;
        return num
    }


    public fun abs_difference(a:u256,b:u256) : u256 {
        if(a>b) return a-b
        else b-a
    }


}