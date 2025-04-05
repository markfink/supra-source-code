// Copyright (c) Supra Oracle.
// SPDX-License-Identifier: MIT

/// Auction:
/// Owner - The owner of the package can perform the `add` and remove free-node address from whitelist.
/// View - There are some functions to retrieve whitelisted free-node address
module supra_addr::free_node {
    use aptos_std::table;
    use aptos_std::vector;

    use std::error;

    use supra_framework::object;
    use supra_addr::supra_util;

    /// Free-node address is already exist
    const EALREADY_EXIST: u64 = 1;
    /// Free-noe address not exist
    const ENOT_EXIST: u64 = 2;
    /// Invalid free-node addresses or empty list
    const EINVALID_ARGUMENT_ADDRESS: u64 = 3;

    const SEED_WHITELIST: vector<u8> = b"free_node::WhitelistFreeNode";

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct WhitelistFreeNode has key {
        free_nodes: table::Table<address, bool>
    }

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct ObjectController has key {
        transfer_ref: object::TransferRef,
        extend_ref: object::ExtendRef,
    }

    /// Internal - DkgState implementation functions
    fun create_whitelist_free_node(owner_signer: &signer) {
        let cons_ref = object::create_named_object(owner_signer, SEED_WHITELIST);
        let object_signer = object::generate_signer(&cons_ref);
        move_to(&object_signer, WhitelistFreeNode { free_nodes: table::new() });
        move_to(&object_signer, ObjectController {
            transfer_ref: object::generate_transfer_ref(&cons_ref),
            extend_ref: object::generate_extend_ref(&cons_ref)
        });
    }

    /// Its Initial function which will be executed automatically while deployed packages
    fun init_module(owner_signer: &signer) {
        create_whitelist_free_node(owner_signer);
    }

    /// Add free-node address into whitelist, if already exist then it gives an error
    /// Only Owner can perform this action
    public entry fun add_whitelist(owner_signer: &signer, free_node_addr: address) acquires WhitelistFreeNode {
        let whitelist_address = get_whitelist_object_address();
        supra_util::ensure_object_owner(object::address_to_object<ObjectController>(whitelist_address), owner_signer);

        ensure_not_whitelisted(whitelist_address, free_node_addr);
        let whitelist_free_nodes = borrow_global_mut<WhitelistFreeNode>(whitelist_address);
        table::add(&mut whitelist_free_nodes.free_nodes, free_node_addr, true);
    }

    /// Add free-node addresses in bulk into whitelist, if already exist then it skip
    /// Only Owner can perform this action
    public entry fun add_whitelist_bulk(
        owner_signer: &signer,
        free_node_addresses: vector<address>
    ) acquires WhitelistFreeNode {
        let whitelist_address = get_whitelist_object_address();
        supra_util::ensure_object_owner(object::address_to_object<ObjectController>(whitelist_address), owner_signer);

        let free_node_len = vector::length(&free_node_addresses);
        assert!(free_node_len != 0, error::invalid_argument(EINVALID_ARGUMENT_ADDRESS));

        let whitelist_free_nodes = borrow_global_mut<WhitelistFreeNode>(whitelist_address);

        while (!vector::is_empty(&free_node_addresses)) {
            let free_node_addr = vector::pop_back(&mut free_node_addresses);
            if (!table::contains(&whitelist_free_nodes.free_nodes, free_node_addr)) {
                table::add(&mut whitelist_free_nodes.free_nodes, free_node_addr, true);
            }
        };
    }

    /// Remove free-node address from whitelist, if address not exist then abort the transaction
    /// Only Owner can perform this action
    public entry fun remove_whitelist(owner_signer: &signer, free_node_addr: address) acquires WhitelistFreeNode {
        let whitelist_address = get_whitelist_object_address();
        supra_util::ensure_object_owner(object::address_to_object<ObjectController>(whitelist_address), owner_signer);

        ensure_whitelisted(whitelist_address, free_node_addr);

        let whitelist_free_nodes = borrow_global_mut<WhitelistFreeNode>(whitelist_address);
        table::remove(&mut whitelist_free_nodes.free_nodes, free_node_addr);
    }

    /// Remove free-node addresses in bulk into whitelist, if address not exist then skip it
    /// Only Owner can perform this action
    public entry fun remove_whitelist_bulk(
        owner_signer: &signer,
        free_node_addresses: vector<address>
    ) acquires WhitelistFreeNode {
        let whitelist_address = get_whitelist_object_address();
        supra_util::ensure_object_owner(object::address_to_object<ObjectController>(whitelist_address), owner_signer);

        let free_node_len = vector::length(&free_node_addresses);
        assert!(free_node_len != 0, error::invalid_argument(EINVALID_ARGUMENT_ADDRESS));

        let whitelist_free_nodes = borrow_global_mut<WhitelistFreeNode>(whitelist_address);
        while (!vector::is_empty(&free_node_addresses)) {
            let free_node_addr = vector::pop_back(&mut free_node_addresses);
            if (table::contains(&whitelist_free_nodes.free_nodes, free_node_addr)) {
                table::remove(&mut whitelist_free_nodes.free_nodes, free_node_addr);
            };
        };
    }

    #[view]
    /// It will check that free-node address is whitelisted or not, return boolean
    public fun is_whitelisted(resource_addr: address, free_node_addr: address): bool acquires WhitelistFreeNode {
        let whitelist_free_nodes = borrow_global<WhitelistFreeNode>(resource_addr);
        table::contains(&whitelist_free_nodes.free_nodes, free_node_addr)
    }

    /// ensure that free-node address is whitelisted otherwise fail
    fun ensure_whitelisted(resource_addr: address, free_node_addr: address) acquires WhitelistFreeNode {
        assert!(is_whitelisted(resource_addr, free_node_addr), error::not_found(ENOT_EXIST));
    }

    /// ensure that free-node address is not whitelisted otherwise fail
    fun ensure_not_whitelisted(resource_addr: address, free_node_addr: address) acquires WhitelistFreeNode {
        assert!(!is_whitelisted(resource_addr, free_node_addr), error::already_exists(EALREADY_EXIST));
    }

    #[view]
    public fun get_whitelist_object_address(): address {
        return object::create_object_address(&@supra_addr, SEED_WHITELIST)
    }

    #[test_only]
    public fun add_whitelist_test(supra: &signer, free_node_address: address) acquires WhitelistFreeNode {
        let whitelist_object_address = get_whitelist_object_address();

        if (object::object_exists<WhitelistFreeNode>(whitelist_object_address)) {
            add_whitelist(supra, free_node_address);
        } else {
            let cons_ref = object::create_named_object(supra, SEED_WHITELIST);
            let object_signer = object::generate_signer(&cons_ref);
            move_to(&object_signer, WhitelistFreeNode { free_nodes: table::new() });
            move_to(&object_signer, ObjectController {
                transfer_ref: object::generate_transfer_ref(&cons_ref),
                extend_ref: object::generate_extend_ref(&cons_ref)
            });
            add_whitelist(supra, free_node_address);
        }
    }

    #[test(supra = @supra_addr)]
    /// Add free-node address in whitelist - positive scenario
    fun test_add_whitelist(supra: &signer) acquires WhitelistFreeNode {
        init_module(supra);
        let free_node_address = @0xf1;
        add_whitelist_test(supra, free_node_address);

        let resource_addr = get_whitelist_object_address();
        assert!(is_whitelisted(resource_addr, free_node_address), error::not_found(1));
    }

    #[test(supra = @supra_addr)]
    #[expected_failure(abort_code = 524289, location = Self)]
    /// Add same free-node address in whitelist two time - negative scenario
    fun test_add_whitelist_failure(supra: &signer) acquires WhitelistFreeNode {
        init_module(supra);
        let free_node_address = @0xf1;
        let whitelist_object_address = get_whitelist_object_address();

        add_whitelist(supra, free_node_address);
        assert!(is_whitelisted(whitelist_object_address, free_node_address), error::not_found(3));

        add_whitelist(supra, free_node_address);
    }

    #[test(supra = @supra_addr)]
    /// Add multiple free-node addresses in whitelist - positive scenario
    fun test_add_whitelist_bulk(supra: &signer) acquires WhitelistFreeNode {
        init_module(supra);
        let free_node_address_1 = @0xf1;
        let free_node_address_2 = @0xf2;
        let free_node_address_3 = @0xf1; // same address as free-node 1, but it will not add again (skipped)
        let whitelist_object_address = get_whitelist_object_address();

        add_whitelist_bulk(supra, vector[free_node_address_1, free_node_address_2, free_node_address_3]);
        assert!(is_whitelisted(whitelist_object_address, free_node_address_1), error::not_found(4));
        assert!(is_whitelisted(whitelist_object_address, free_node_address_2), error::not_found(5));
    }

    #[test(supra = @supra_addr)]
    /// Add free-node address and then remove it from whitelist - positive scenario
    fun test_remove_whitelist(supra: &signer) acquires WhitelistFreeNode {
        init_module(supra);
        let free_node_address = @0xf1;
        let whitelist_object_address = get_whitelist_object_address();

        add_whitelist(supra, free_node_address);
        assert!(is_whitelisted(whitelist_object_address, free_node_address), error::not_found(7));

        remove_whitelist(supra, free_node_address);
        assert!(!is_whitelisted(whitelist_object_address, free_node_address), error::not_found(8));
    }

    #[test(supra = @supra_addr)]
    #[expected_failure(abort_code = 393218, location = Self)]
    /// Remove a free-node address from the whitelist that doesn't even exist in whitelistFreeNode - negative scenario
    fun test_remove_whitelist_failure(supra: &signer) acquires WhitelistFreeNode {
        init_module(supra);
        let free_node = @0xf1;
        let whitelist_object_address = get_whitelist_object_address();

        remove_whitelist(supra, free_node);
        assert!(!is_whitelisted(whitelist_object_address, free_node), error::not_found(9));
    }
}
