use gtk::glib::{self, ControlFlow};
use gtk::prelude::*;
use gtk::{Align, Application, ApplicationWindow, Box, Button, Label, Orientation};
use std::cell::Cell;
use std::ffi::CStr;
use std::os::raw::c_char;
use std::rc::Rc;
use std::time::Duration;

#[repr(C)]
struct SoundbarConnection {
    _private: [u8; 0],
}

extern "C" {
    fn soundbar_connection_start() -> *mut SoundbarConnection;
    fn soundbar_connection_poll(
        connection: *mut SoundbarConnection,
        status: *mut c_char,
        status_len: usize,
        finished: *mut i32,
        ok: *mut i32,
    );
    fn soundbar_connection_free(connection: *mut SoundbarConnection);
}

fn main() -> glib::ExitCode {
    let app = Application::builder()
        .application_id("nl.matsdeswart.soundbar")
        .build();

    app.connect_activate(build_window);
    app.run()
}

fn build_window(app: &Application) {
    let window = ApplicationWindow::builder()
        .application(app)
        .title("Soundbar")
        .default_width(440)
        .default_height(280)
        .build();

    let root = Box::new(Orientation::Vertical, 12);
    root.set_margin_top(28);
    root.set_margin_bottom(28);
    root.set_margin_start(28);
    root.set_margin_end(28);
    root.set_valign(Align::Center);

    let title = Label::new(Some("Samsung Soundbar K450"));
    title.add_css_class("title-1");
    let detail = Label::new(Some("Verbindt alleen het audio-profiel, daarna gaat het geluid erheen."));
    detail.set_wrap(true);
    detail.set_justify(gtk::Justification::Center);
    detail.set_halign(Align::Center);
    detail.add_css_class("dim-label");

    let button = Button::with_label("Verbind");
    button.add_css_class("suggested-action");
    button.set_halign(Align::Center);

    let status = Label::new(Some("Klaar om te verbinden."));
    status.set_wrap(true);
    status.set_max_width_chars(40);
    status.set_justify(gtk::Justification::Center);
    status.set_halign(Align::Center);

    root.append(&title);
    root.append(&detail);
    root.append(&button);
    root.append(&status);
    window.set_child(Some(&root));

    let connection: Rc<Cell<*mut SoundbarConnection>> = Rc::new(Cell::new(std::ptr::null_mut()));
    let polling = Rc::new(Cell::new(false));

    let button_for_click = button.clone();
    let status_for_click = status.clone();
    let connection_for_click = connection.clone();
    button.connect_clicked(move |_| {
        if !connection_for_click.get().is_null() {
            return;
        }
        button_for_click.set_sensitive(false);
        button_for_click.set_label("Bezig…");
        status_for_click.set_text("Bluetooth openen…");
        connection_for_click.set(unsafe { soundbar_connection_start() });
    });

    let button_for_poll = button.clone();
    let status_for_poll = status.clone();
    let connection_for_poll = connection.clone();
    let polling_for_poll = polling.clone();
    glib::timeout_add_local(Duration::from_millis(200), move || {
        let ptr = connection_for_poll.get();
        if ptr.is_null() || polling_for_poll.get() {
            return ControlFlow::Continue;
        }
        polling_for_poll.set(true);
        let mut buf = [0u8; 512];
        let mut finished = 0;
        let mut ok = 0;
        unsafe {
            soundbar_connection_poll(
                ptr,
                buf.as_mut_ptr() as *mut c_char,
                buf.len(),
                &mut finished,
                &mut ok,
            );
        }
        let text = CStr::from_bytes_until_nul(&buf)
            .ok()
            .and_then(|value| value.to_str().ok())
            .unwrap_or("Bezig…");
        status_for_poll.set_text(text);
        if finished != 0 {
            unsafe { soundbar_connection_free(ptr) };
            connection_for_poll.set(std::ptr::null_mut());
            button_for_poll.set_sensitive(true);
            button_for_poll.set_label(if ok != 0 { "Opnieuw verbinden" } else { "Verbind" });
        }
        polling_for_poll.set(false);
        ControlFlow::Continue
    });

    window.connect_close_request(move |_| {
        let ptr = connection.get();
        if !ptr.is_null() {
            unsafe { soundbar_connection_free(ptr) };
            connection.set(std::ptr::null_mut());
        }
        glib::Propagation::Proceed
    });

    window.present();
}
