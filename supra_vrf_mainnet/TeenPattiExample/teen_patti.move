module teen_patti::teen_patti {
    use aptos_std::table;
    use supra_addr::supra_vrf;
    use std::string;

    struct RandomNumberList has key {
        random_numbers: table::Table<u64, vector<u256>>
    }

    fun init_module(sender: &signer) {
        move_to(sender, RandomNumberList { random_numbers: table::new() });
    }

    public entry fun rng_request(
        sender: &signer,
        rng_count: u8,
        client_seed: u64,
        num_confirmations: u64
    ) acquires RandomNumberList {
        let callback_address = @teen_patti;
        let callback_module = string::utf8(b"teen_patti");
        let callback_function = string::utf8(b"distribute");
        let nonce = supra_vrf::rng_request(
            sender,
            callback_address,
            callback_module,
            callback_function,
            rng_count,
            client_seed,
            num_confirmations
        );

        let random_num_list = &mut borrow_global_mut<RandomNumberList>(@teen_patti).random_numbers;
        table::add(random_num_list, nonce, vector[]);
    }

    public entry fun distribute(
        nonce: u64,
        message: vector<u8>,
        signature: vector<u8>,
        caller_address: address,
        rng_count: u8,
        client_seed: u64,
    ) acquires RandomNumberList {
        let verified_num: vector<u256> = supra_vrf::verify_callback(
            nonce,
            message,
            signature,
            caller_address,
            rng_count,
            client_seed
        );
        let random_num_list = &mut borrow_global_mut<RandomNumberList>(@teen_patti).random_numbers;
        let random_num = table::borrow_mut(random_num_list, nonce);
        *random_num = verified_num;
    }

    #[view]
    public fun get_rng_number_from_nonce(nonce: u64): vector<u256> acquires RandomNumberList {
        let random_num_list = borrow_global<RandomNumberList>(@teen_patti);
        *table::borrow(&random_num_list.random_numbers, nonce)
    }
}
