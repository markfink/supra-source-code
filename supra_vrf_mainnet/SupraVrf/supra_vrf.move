module supra_addr::supra_vrf {
    use aptos_std::table;

    use std::error;
    use std::signer;
    use std::string::String;

    use supra_framework::block;
    use supra_framework::timestamp;
    use supra_framework::event;
    use supra_framework::object;

    use supra_addr::deposit;
    use supra_addr::free_node;
    use supra_addr::supra_util;

    /// Unauthorized sender/free-node to call this method
    const EUNAUTHORIZED_FREE_NODE: u64 = 1;
    /// Signature validation failed
    const EINVALID_SIGNATURE: u64 = 2;
    /// Request parameters hex is valid as message
    const EINVALID_MESSAGE: u64 = 3;
    /// Client or there contract is not whitelisted
    const EINVALID_CLIENT_CONTRACT: u64 = 4;
    /// Min balance reached to call this method
    const EMIN_BALANCE_REACHED: u64 = 5;
    /// Rng count should be more than zero
    const EINVALID_RNG_REQUEST: u64 = 6;
    /// Nonce Already executed
    const ENONCE_ALREADY_EXECUTED: u64 = 7;
    /// Only Authorized users can access it
    const EUNAUTHORIZED_ACCESS: u64 = 8;

    /// Defined Oracle seeds that are used for creating object
    const SEED_CONFIG: vector<u8> = b"supra_vrf::Config";
    /// Defined DKG seeds that are used for creating object
    const SEED_DKG: vector<u8> = b"supra_vrf::DkgState";
    /// Defined Nonce processed that are used for creating object
    const SEED_NONCE_PROCESSED: vector<u8> = b"supra_vrf::ProcessedNonce";

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    /// Manage request nonce and instance_id
    struct Config has key, store {
        nonce: u64,
        instance_id: u64,
    }

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    /// Store public key of dkg
    struct DkgState has key {
        public_key: vector<u8>
    }

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    /// Processed Nonce list store
    struct ProcessedNonce has key, store {
        nonce_list: table::Table<u64, bool>
    }

    #[event]
    struct RequestEvent has drop, store {
        nonce: u64,
        instance_id: u64,
        caller_address: address,
        callback_address: address,
        callback_module: String,
        callback_function: String,
        rng_count: u8,
        client_seed: u64,
        num_confirmations: u64,
        block_number: u64,
    }

    #[event]
    /// Update Public Key event
    struct UpdatePublicKeyEvent has store, drop { public_key: vector<u8>, timestamp: u64 }

    #[event]
    /// Request Nonce processed event
    struct NonceProcessedEvent has drop, store { nonce: u64, timestamp: u64, block_number: u64 }

    #[event]
    /// Client has verified the signature
    struct VerifyCallbackEvent has drop, store { nonce: u64, timestamp: u64 }

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct ObjectController has key {
        transfer_ref: object::TransferRef,
        extend_ref: object::ExtendRef,
    }

    /// Internal - Create initial configuration functions
    fun create_config(owner_signer: &signer) {
        let cons_ref = object::create_named_object(owner_signer, SEED_CONFIG);
        let object_signer = object::generate_signer(&cons_ref);
        move_to(&object_signer, Config { nonce: 0, instance_id: 1 });
        move_to(&object_signer, ObjectController {
            transfer_ref: object::generate_transfer_ref(&cons_ref),
            extend_ref: object::generate_extend_ref(&cons_ref)
        });
    }

    /// Internal - DkgState implementation functions
    fun create_dkg_state(owner_signer: &signer) {
        let cons_ref = object::create_named_object(owner_signer, SEED_DKG);
        let object_signer = object::generate_signer(&cons_ref);
        move_to(&object_signer, DkgState { public_key: vector[] });
        move_to(&object_signer, ObjectController {
            transfer_ref: object::generate_transfer_ref(&cons_ref),
            extend_ref: object::generate_extend_ref(&cons_ref)
        });
    }

    /// Internal - Create nonce processed object
    fun create_nonce_processed(owner_signer: &signer) {
        let cons_ref = object::create_named_object(owner_signer, SEED_NONCE_PROCESSED);
        let object_signer = object::generate_signer(&cons_ref);
        move_to(&object_signer, ProcessedNonce { nonce_list: table::new() });
        move_to(&object_signer, ObjectController {
            transfer_ref: object::generate_transfer_ref(&cons_ref),
            extend_ref: object::generate_extend_ref(&cons_ref)
        });
    }

    /// Its Initial function which will be executed automatically while deployed packages
    fun init_module(owner_signer: &signer) {
        create_config(owner_signer);
        create_dkg_state(owner_signer);
        create_nonce_processed(owner_signer)
    }

    /// Only Owner can perform this action
    /// if object already exist then it will update the existing object dkg public_key, otherwise return error
    public entry fun update_public_key(owner_signer: &signer, public_key: vector<u8>) acquires DkgState {
        let dkg_address = get_dkg_object_address();
        supra_util::ensure_object_owner(object::address_to_object<ObjectController>(dkg_address), owner_signer);

        let dkg = borrow_global_mut<DkgState>(dkg_address);
        dkg.public_key = public_key;

        // emit event that public key has been created/updated
        event::emit(UpdatePublicKeyEvent { public_key, timestamp: timestamp::now_seconds() });
    }

    /// public entry function to random number generator request
    /// Third party will use this function
    public fun rng_request(
        sender: &signer,
        callback_address: address,
        callback_module: String,
        callback_function: String,
        rng_count: u8,
        client_seed: u64,
        num_confirmations: u64,
    ): u64 acquires Config {
        let caller_address = signer::address_of(sender);

        let deposit_management_addr = deposit::get_deposit_management_object_address();
        // ensure that contract is enabled to take request
        deposit::ensure_contract_enabled(deposit_management_addr);

        // Now, it will first check whether the caller and the contract making the request are eligible or not.
        assert!(
            deposit::is_contract_eligible(caller_address, callback_address),
            error::permission_denied(EINVALID_CLIENT_CONTRACT)
        );

        // After that, it's time to check if the minimum balance for the client has been reached.
        assert!(!deposit::has_minimum_balance_reached(caller_address), error::out_of_range(EMIN_BALANCE_REACHED));

        // rng count should be more than 0
        assert!(rng_count > 0, error::invalid_argument(EINVALID_RNG_REQUEST));

        // we want the max cap of num_confirmations to be 20
        if (num_confirmations > 20) { num_confirmations = 20; };

        // retrieve config address from config_seed and borrow it from storage
        let config = borrow_global_mut<Config>(get_config_object_address());
        config.nonce = config.nonce + 1;
        let nonce = config.nonce;

        // get current block number
        let block_number = block::get_current_block_height();
        event::emit(
            RequestEvent { nonce, instance_id: config.instance_id, caller_address, callback_address, callback_module, callback_function, rng_count, client_seed, num_confirmations, block_number }
        );
        nonce
    }

    /// public function to verify callback
    /// Clients will use this function to ensure that the callback parameters are not malicious
    /// first it will verify the message and the signature
    /// and after that it will return random numbers in vector
    /// Update: It's not required to check if the caller is whitelisted here
    public fun verify_callback(
        nonce: u64,
        message: vector<u8>,
        signature: vector<u8>,
        caller_address: address,
        rng_count: u8,
        client_seed: u64,
    ): vector<u256> acquires DkgState, Config {
        // check message is proper or not
        let instance_id = borrow_global<Config>(get_config_object_address()).instance_id;
        let message_hash = supra_util::message_hash(nonce, instance_id, caller_address, rng_count, client_seed);
        assert!(message == message_hash, error::invalid_argument(EINVALID_MESSAGE));

        // get public key from storage and verify against signature
        let dkg = borrow_global<DkgState>(get_dkg_object_address());
        assert!(supra_util::verify_signature(dkg.public_key, message, signature), error::internal(EINVALID_SIGNATURE));

        event::emit(VerifyCallbackEvent { nonce, timestamp: timestamp::now_microseconds() });

        supra_util::get_random_numbers(signature, rng_count, client_seed)
    }

    /// It will collect the vrf response transaction fee from client's wallet
    public fun collect_tx_fee_from_client(
        sender: &signer,
        client_address: address,
        amount: u64,
        nonce: u64
    ) acquires ProcessedNonce {
        // check free-node whitelist
        let sender_addr = signer::address_of(sender);
        let whitelist_object_addr = free_node::get_whitelist_object_address();
        assert!(
            free_node::is_whitelisted(whitelist_object_addr, sender_addr),
            error::unauthenticated(EUNAUTHORIZED_FREE_NODE)
        );

        // verify if this nonce has been processed before
        let processed_nonce = borrow_global_mut<ProcessedNonce>(get_nonce_processed_object_address());
        assert!(!table::contains(&processed_nonce.nonce_list, nonce), error::aborted(ENONCE_ALREADY_EXECUTED));
        table::add(&mut processed_nonce.nonce_list, nonce, true);

        deposit::collect_fund(client_address, amount, nonce);

        // add event that nonce is processed
        event::emit(
            NonceProcessedEvent {
                nonce, timestamp: timestamp::now_microseconds(), block_number: block::get_current_block_height()
            }
        );
    }

    #[view]
    public fun get_dkg_object_address(): address {
        return object::create_object_address(&@supra_addr, SEED_DKG)
    }

    #[view]
    public fun get_config_object_address(): address {
        return object::create_object_address(&@supra_addr, SEED_CONFIG)
    }

    #[view]
    public fun get_nonce_processed_object_address(): address {
        return object::create_object_address(&@supra_addr, SEED_NONCE_PROCESSED)
    }

    #[test_only]
    use supra_framework::account;

    #[test(supra = @supra_addr, free_node = @0xf1, supra_framework = @supra_framework)]
    fun test_verify_sign_success(
        supra: &signer,
        free_node: &signer,
        supra_framework: &signer
    ) acquires DkgState, Config {
        let account_addr: address = signer::address_of(supra);
        account::create_account_for_test(account_addr); // create test accounts
        account::create_account_for_test(signer::address_of(supra_framework));

        supra_framework::timestamp::set_time_has_started_for_testing(supra_framework);

        init_module(supra);
        free_node::add_whitelist_test(supra, signer::address_of(free_node));

        let pub_key = vector[174, 250, 186, 145, 151, 68, 101, 103, 150, 85, 33, 195, 208, 211, 117, 232, 107, 115, 120, 241, 196, 15, 181, 84, 139, 52, 176, 6, 78, 171, 109, 85, 88, 161, 66, 102, 208, 83, 168, 34, 127, 255, 70, 68, 180, 106, 21, 152];
        update_public_key(supra, pub_key);

        let nonce = 8;
        let msg = vector[206, 29, 113, 110, 62, 239, 184, 94, 113, 101, 205, 188, 4, 195, 213, 173, 126, 164, 244, 87, 212, 13, 69, 242, 144, 97, 84, 138, 222, 132, 112, 43];
        let sign = vector[182, 227, 136, 103, 196, 80, 68, 254, 178, 146, 53, 202, 205, 53, 186, 104, 0, 252, 55, 156, 51, 29, 207, 25, 65, 67, 29, 189, 5, 85, 124, 219, 31, 79, 214, 196, 135, 121, 221, 217, 145, 167, 94, 104, 230, 116, 147, 82, 8, 123, 68, 32, 135, 240, 181, 26, 56, 216, 73, 33, 238, 102, 127, 199, 139, 53, 247, 33, 82, 105, 91, 66, 56, 103, 253, 26, 255, 193, 165, 83, 57, 36, 116, 187, 140, 180, 145, 245, 254, 99, 69, 50, 85, 179, 139, 233];
        let caller_address = @0x35d8bd9997a22baa29342f30e615b6541f29fcc531d706f5af84f0449f169b69;
        let rng_count: u8 = 1;
        let client_seed: u64 = 1;
        let random_numbers: vector<u256> = verify_callback(nonce, msg, sign, caller_address, rng_count, client_seed);

        assert!((rng_count as u64) == std::vector::length(&random_numbers), 0);
    }
}
