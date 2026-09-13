//! Apply server pages to the authoritative rows. Task 7 fills this in.
use crate::store::ClientStore;
use crate::{ApplyReport, Client};
use otter_core::{PullPage, Result, invalid};

impl<S: ClientStore> Client<S> {
    pub fn apply_page(&mut self, _page: PullPage) -> Result<ApplyReport> {
        Err(invalid("not yet implemented"))
    }
}
