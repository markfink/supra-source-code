module supra_oracle::supra_oracle_verifier {

    use std::error;
    use std::vector;
    use aptos_std::simple_map::{Self, SimpleMap};
    use supra_framework::object;
    use supra_framework::event;
    use supra_framework::timestamp;
    use supra_framework::multisig_account;
    use supra_utils::utils;

    /// Committee id -> public key mapping is missing from the map
    const ECOMMITTEE_KEY_DOES_NOT_EXIST: u64 = 200;
    /// Invalid Public key lnput
    const EINVALID_PUBLIC_KEY: u64 = 201;
    /// Invalid Multisig account
    const EINVALID_MULTISIG_ACCOUNT: u64 = 203;

    /// define public key length
    const PUBLIC_KEY_LENGTH: u64 = 48;

    /// Defined DKG seeds that are used for creating resources
    const SEED_DKG: vector<u8> = b"supra_oracle_verifier::DkgState";

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct DkgStateObjectController has key {
        transfer_ref: object::TransferRef,
        extend_ref: object::ExtendRef,
    }


    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    /// Manage DKG pubkey key to verify BLS signature
    struct DkgState has key, store {
        // map from committee-id to the committee public key
        com_to_pub_key: SimpleMap<u64, vector<u8>>,
    }

    #[event]
    /// Update Public Key event
    struct PublicKeyAdded has store, drop { committee_id: u64, public_key: vector<u8>, timestamp: u64 }

    #[event]
    /// Update Public Key event
    struct PublicKeyRemoved has store, drop { committee_id: u64, public_key: vector<u8>, timestamp: u64 }

    /// Its Initial function which will be executed automatically while deployed packages
    /// deployment should only done from admin account (not freenode)
    fun init_module(owner_signer: &signer) {
        let cons_ref = object::create_named_object(owner_signer,SEED_DKG);
        let object_signer = object::generate_signer(&cons_ref);
        move_to(&object_signer,DkgStateObjectController{transfer_ref:object::generate_transfer_ref(&cons_ref),extend_ref:object::generate_extend_ref(&cons_ref)});
        move_to(&object_signer, DkgState { com_to_pub_key: simple_map::new() });
    }

    entry fun migrate_to_multisig(owner_signer: &signer, multisig_address:address) acquires DkgStateObjectController {
        assert!(
            multisig_account::num_signatures_required(multisig_address) >= 2,
            error::invalid_state(EINVALID_MULTISIG_ACCOUNT)
        );
        let dkg_address = get_dkg_object_address();
        utils::ensure_object_owner(object::address_to_object<DkgStateObjectController>(dkg_address),owner_signer);
        let object_controller = borrow_global_mut<DkgStateObjectController>(dkg_address);
        let linear_transfer_ref = object::generate_linear_transfer_ref(&object_controller.transfer_ref);
        object::transfer_with_ref(linear_transfer_ref,multisig_address);
    }

    /// Only Multisig account can perform this action
    /// This function add/updates the public key associated with the given `committee_id` in the `DkgState`.
    public entry fun add_committee_public_key(
        owner_signer: &signer,
        committee_id: u64,
        public_key: vector<u8>
    ) acquires DkgState {
        let dkg_address = get_dkg_object_address();
        utils::ensure_object_owner(object::address_to_object<DkgState>(dkg_address),owner_signer);
        assert!(vector::length(&public_key) == PUBLIC_KEY_LENGTH, error::invalid_argument(EINVALID_PUBLIC_KEY));

        let dkg_state = borrow_global_mut<DkgState>(dkg_address);
        simple_map::upsert(&mut dkg_state.com_to_pub_key, committee_id, public_key);


        let timestamp = timestamp::now_seconds();
        // emit event that `committee_id` publickey has been added/updated
        let public_key_event = PublicKeyAdded { committee_id, public_key, timestamp };
        event::emit(public_key_event);
    }

    /// Only Multisig account can perform this action
    /// This function remove the public key associated with the given `committee_id` from the `DkgState`.
    public entry fun remove_committee_public_key(
        owner_signer: &signer,
        committee_id: u64
    ) acquires DkgState {
        let dkg_address = get_dkg_object_address();
        utils::ensure_object_owner(object::address_to_object<DkgState>(dkg_address),owner_signer);
        let dkg_state = borrow_global_mut<DkgState>(dkg_address);

        ensure_committee_public_key_exist(dkg_state, committee_id);
        let (_, public_key) = simple_map::remove(&mut dkg_state.com_to_pub_key, &committee_id);

        let timestamp = timestamp::now_seconds();
        // emit event that `committee_id` publickey has been added/updated
        let public_key_event = PublicKeyRemoved { committee_id, public_key, timestamp };
        event::emit(public_key_event);
    }

    /// Committee signature verification
    public fun committee_sign_verification(
        committee_id: u64,
        root: vector<u8>,
        sign: vector<u8>
    ): bool acquires DkgState {
        let public_key = get_committee_public_key(committee_id);
        utils::verify_signature(public_key, root, sign)
    }

    /// Internal function - ensure that committee public key is exist in the DkgState
    fun ensure_committee_public_key_exist(dkg_state: &DkgState, committee_id: u64) {
        assert!(
            simple_map::contains_key(&dkg_state.com_to_pub_key, &committee_id),
            error::not_found(ECOMMITTEE_KEY_DOES_NOT_EXIST)
        );
    }

    #[view]
    public fun get_committee_public_key(committee_id: u64): vector<u8> acquires DkgState {
        let dkg_state = borrow_global<DkgState>(get_dkg_object_address());
        ensure_committee_public_key_exist(dkg_state, committee_id);
        *simple_map::borrow(&dkg_state.com_to_pub_key, &committee_id)
    }

    #[view]
    public fun get_committee_public_key_length(): u64 acquires DkgState {
        let dkg_state = borrow_global<DkgState>(get_dkg_object_address());
        simple_map::length(&dkg_state.com_to_pub_key)
    }

    #[view]
    public fun get_dkg_object_address() : address {
        return object::create_object_address(&@supra_oracle, SEED_DKG)
    }

    #[test_only]
    public fun add_committee_public_key_for_test(
        owner_signer: &signer,
        committee_id: u64,
        public_key: vector<u8>
    ) acquires DkgState {
        assert!(vector::length(&public_key) == PUBLIC_KEY_LENGTH, error::invalid_argument(EINVALID_PUBLIC_KEY));
        if (exists<DkgState>(get_dkg_object_address())) {
            let dkg_state = borrow_global_mut<DkgState>(get_dkg_object_address());
            simple_map::upsert(&mut dkg_state.com_to_pub_key, committee_id, public_key);
        } else {
            let cons_ref = object::create_named_object(owner_signer, SEED_DKG);
            let object_signer = object::generate_signer(&cons_ref);
            let pubkey_map = simple_map::new<u64, vector<u8>>();
            simple_map::add(&mut pubkey_map, committee_id, public_key);
            move_to(&object_signer, DkgState { com_to_pub_key: pubkey_map });
        }
    }

    #[test_only]
    fun remove_committee_public_key_test(_owner_signer: &signer, committee_id: u64, ) acquires DkgState {
        let dkg_state = borrow_global_mut<DkgState>(get_dkg_object_address());
        simple_map::remove(&mut dkg_state.com_to_pub_key, &committee_id);
    }

    #[test(admin = @supra_oracle, multisign = @supra_oracle, supra_framework = @supra_framework)]
    fun test_add_remove_committe_public_key(
        admin: &signer,
        multisign: &signer,
        supra_framework: &signer
    ) acquires DkgState {
        use supra_framework::account;
        use supra_framework::timestamp;
        use aptos_std::signer;
        use std::vector;

        account::create_account_for_test(signer::address_of(admin));
        account::create_account_for_test(signer::address_of(multisign));
        timestamp::set_time_has_started_for_testing(supra_framework);
        init_module(multisign);

        let committee_ids = vector[1, 2];
        let public_keys = vector[x"98fb3cbe8c93393d92d8c106c19788d80695a3af70d6537ee4b4973f9b3b1238c0264fe4e6dd3989932022ed96c875a3", x"a4772aee49b4f1fbf30b36a101dea307b71316226f772fada3ae547cb9793740c11893105286082536c46b3a1ac929bf"];
        add_committee_public_key_for_test(
            multisign,
            *vector::borrow(&committee_ids, 0),
            *vector::borrow(&public_keys, 0)
        );
        add_committee_public_key_for_test(
            multisign,
            *vector::borrow(&committee_ids, 1),
            *vector::borrow(&public_keys, 1)
        );

        assert!(get_committee_public_key_length() == vector::length(&committee_ids), 1);

        while (!vector::is_empty(&committee_ids)) {
            let committee_id = vector::pop_back(&mut committee_ids);
            assert!(get_committee_public_key(committee_id) == vector::pop_back(&mut public_keys), 2);
        };

        remove_committee_public_key_test(multisign, 1);
        remove_committee_public_key_test(multisign, 2);
        assert!(get_committee_public_key_length() == 0, 3);
    }
}
