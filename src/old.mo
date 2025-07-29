module {

    public type NTC2Can_request_shared = {
        amount : Nat;
        canister : Principal;
        retry : Nat;
        last_try : Nat64;
    };

    public type NTC2Can_request = {
        amount : Nat;
        canister : Principal;
        var retry : Nat;
        var last_try : Nat64;
    };

}