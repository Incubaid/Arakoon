open OUnit
let suite = 
  "correctness" >::: 
    [ Bstore_test.suite;
      Core_test.suite;
      Arakoon_remote_client_test.suite;
      Routing_test.suite;
      Remote_admin_test.suite;
    ]
