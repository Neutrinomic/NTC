import ICRCLedger "mo:devefi-icrc-ledger";
import ICL "mo:devefi-icrc-ledger/icrc_ledger";
import IC "./services/ic";
import ICPLedger "mo:devefi-icp-ledger";
import Principal "mo:base/Principal";
import Account "mo:account";
import Debug "mo:base/Debug";
import Timer "mo:base/Timer";
import Blob "mo:base/Blob";
import Iter "mo:base/Iter";
import Array "mo:base/Array";
import Float "mo:base/Float";
import Nat "mo:base/Nat";
import Cycles "mo:base/ExperimentalCycles";
import BTree "mo:stableheapbtreemap/BTree";
import Nat64 "mo:base/Nat64";
import IT "mo:itertools/Iter";
import List "mo:base/List";

actor class NTCminter() = this {

    let T = 1_000_000_000_000;
    let NTC_ledger_id = "n6tkf-tqaaa-aaaal-qsneq-cai"; // Ledger needs to be 12 decimals

    stable let NTC_mem_v1 = ICRCLedger.Mem.Ledger.V1.new();
    let NTC_ledger = ICRCLedger.Ledger<system>(NTC_mem_v1, NTC_ledger_id, #last, Principal.fromActor(this));

    stable let ICP_mem_v1 = ICPLedger.Mem.Ledger.V1.new();
    let ICP_ledger = ICPLedger.Ledger<system>(ICP_mem_v1, "ryjl3-tyaaa-aaaaa-aaaba-cai", #last, Principal.fromActor(this));

    private let ic : IC.Self = actor ("aaaaa-aa");

    type NTC2Can_request = {
        amount : Nat;
        canister : Principal;
        var retry : Nat;
    };

    stable let NTC2Can_requests = BTree.init<Nat64, NTC2Can_request>(?32); // 32 is the order, or the size of each BTree node

    private func canister2subaccount(canister_id : Principal) : Blob {
        Blob.fromArray(Iter.toArray(IT.pad<Nat8>(Iter.fromArray(Blob.toArray(Principal.toBlob(canister_id))), 32, 0)));
    };

    private func subaccount2canister(subaccount : [Nat8]) : Principal {
        Principal.fromBlob(Blob.fromArray(Array.take(subaccount, 29)));
    };

    ICP_ledger.onReceive(
        func(t) {
            // Here we convert ICP to NTC based on the mint ratio
            // We do it sync, we can burn the ICP later
            if (t.amount < 200000) return;
            // Strategy: Return NTC to the from account

            // TODO: Add to queue similar to NTC2Can

        }
    );

    var unique_request_id : Nat32 = 0;
    let MAX_CYCLE_SEND_CALLS = 10;

    ignore Timer.recurringTimer<system>(
        #seconds(6),
        func() : async () {

            var processing = List.nil<(async (), Nat64, NTC2Can_request)>();

            var i = 0;
            // Make it send MAX_CYCLE_SEND_CALLS requests at a time and then await all
            label sendloop while (i < MAX_CYCLE_SEND_CALLS) { 
                let ?(id, request) = BTree.deleteMax<Nat64, NTC2Can_request>(NTC2Can_requests, Nat64.compare) else continue sendloop;

                if (Cycles.balance() < request.amount) continue sendloop; // If we don't have enough cycles, wait for the ICP to be burned. Make sure we don't delete requests.

                processing := List.push(((with cycles = request.amount) ic.deposit_cycles({ canister_id = request.canister }), id, request), processing);
                i += 1;
            };

            label awaitreq for ((promise, id, req) in List.toIter(processing)) {
                // Await results of all promises
                try {
                    // Q: Can this even trap? When?
                    let _myrefill = await promise; // Await the promise to get the tick data
                } catch (_e) {
                    // Q: If it traps, does it mean we are 100% sure the cycles didn't get sent?
                    // We readd it to the queue, but with a lower id
                    if (req.retry > 10) continue awaitreq;
                    let new_id : Nat64 = ((id >> 32) / 2) << 32 | Nat64.fromNat32(unique_request_id);
                    req.retry += 1;
                    ignore BTree.insert<Nat64, NTC2Can_request>(NTC2Can_requests, Nat64.compare, new_id, req);
                    unique_request_id += 1;
                };
            };

        },
    );

    NTC_ledger.onReceive(
        func(t) {
            // Strategy: Unlike TCycles ledger, we will retry refilling the canister
            // if it doesn't work, the NTC gets burned. No NTC is gets returned if the subaccount is not a valid canister.

            // Here we can convert the subaccount to a canister and send cycles while burning the NTC
            // We are adding these requests to a queue
            if (t.amount < 200000) return;
            let ?subaccount = t.to.subaccount else return;

            // We add them based on amount and request id so we can pick the largest requests first
            let id : Nat64 = ((Nat64.fromNat(t.amount) / 1_0000_0000) << 32) | Nat64.fromNat32(unique_request_id);
            ignore BTree.insert<Nat64, NTC2Can_request>(
                NTC2Can_requests,
                Nat64.compare,
                id,
                {
                    amount = t.amount;
                    canister = subaccount2canister(Blob.toArray(subaccount));
                    var retry = 0;
                },
            );
            unique_request_id += 1;

            // Burn
            ignore do ? {
                ignore NTC_ledger.send({
                    to = NTC_ledger.getMinter()!;
                    amount = t.amount;
                    from_subaccount = ?subaccount;
                });
            };

        }
    );

    public shared ({ caller }) func mint(to : Account.Account) : async () {
        // Here we accept native cycles to mint NTC

        let received = Cycles.accept<system>(Cycles.available());
        if (received < T / 100) return;

        // Mint
        ignore NTC_ledger.send({
            to = to;
            amount = received;
            from_subaccount = null;
        });

    };

    type Stats = {
        cycles : Nat;
    };

    public query func stats() : async Stats {
        {
            cycles = Cycles.balance();
        };
    };

    public query func get_account(canister_id : Principal) : async (Account.Account, Text) {
        let acc : Account.Account = {
            owner = Principal.fromActor(this);
            subaccount = ?canister2subaccount(canister_id);
        };
        (
            acc,
            Account.toText(acc),
        );
    }

};
