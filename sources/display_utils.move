// Copyright (c) 2026 Federico Abrignani. All rights reserved.
/// NPLEX Display Utils
/// 
/// This contract provides the logic for the display utils.
module nplex::display_utils {
    use iota::display;
    use iota::package;
    use std::string::String;

    /// Generic macro to setup display for any type T
    /// Takes keys and values as arguments
    public(package) macro fun setup_display<$T>(
        $publisher: &package::Publisher,
        $keys: vector<String>,
        $values: vector<String>,
        $ctx: &mut TxContext
    ) {
        let mut display = display::new_with_fields<$T>(
            $publisher, $keys, $values, $ctx
        );
        display::update_version(&mut display);
        iota::transfer::public_share_object(display);
    }
}
