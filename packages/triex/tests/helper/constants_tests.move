#[test_only]
module triex::constants_tests {
    use std::unit_test::assert_eq;
    use triex::constants;

    #[test]
    /// Unit and stake constants are pinned to their documented values.
    fun unit_and_stake_constants() {
        assert_eq!(constants::cred_unit(), 1_000_000);
        // 100 CRED, expressed in CRED base units.
        assert_eq!(constants::default_stake_required(), 100 * constants::cred_unit() * 1_000);
    }

    #[test]
    /// EWMA bounds sit above their defaults and the dynamic-field key is stable.
    fun ewma_bounds_and_key() {
        assert_eq!(constants::max_ewma_alpha(), 100_000_000);
        assert_eq!(constants::max_z_score_threshold(), 10 * constants::float_scaling());
        assert!(constants::max_ewma_alpha() >= constants::default_ewma_alpha());
        assert!(constants::max_z_score_threshold() >= constants::default_z_score_threshold());
        assert_eq!(constants::ewma_df_key(), b"ewma");
    }
}
