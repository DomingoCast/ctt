pub const Timestamp = struct {
    unix_secs: i64,
    pub fn lessThan(a: Timestamp, b: Timestamp) bool { return a.unix_secs < b.unix_secs; }
};
