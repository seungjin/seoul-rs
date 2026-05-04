+++
draft = true
title = "[WIP][LRW] 3.4 web_sys"
date = "2026-03-18"
[taxonomies]
authors = ["Seungjin Kim"]
tags = ["wasm", "rust"]
+++

**Cargo.toml**
```toml
~~~~
[features]
default = ["console_error_panic_hook"]

[dependencies]
wasm-bindgen = "0.2.84"
js-sys = "0.3"
console_error_panic_hook = { version = "0.1.7", optional = true }
web-sys = { version = "0.3", features = [
  "Document",
  "Element",
  "HtmlElement",
  "Window",
  "BinaryType",
  "Blob",
  "ErrorEvent",
  "MessageEvent",
  "WebSocket",
  "console",
  "FileReader",
  "ProgressEvent",
  "CloseEvent",
] }

[profile.release]
opt-level = "s"
~~~~
```

**src/lib.rs**
```rust
use wasm_bindgen::prelude::*;
use web_sys::{window, CloseEvent, ErrorEvent, MessageEvent, WebSocket};

macro_rules! console_log {
    ($($t:tt)*) => (log(&format_args!($($t)*).to_string()))
}

#[wasm_bindgen]
extern "C" {
    #[wasm_bindgen(js_namespace = console)]
    fn log(s: &str);
}

#[wasm_bindgen(start)]
fn start_websocket() -> Result<(), JsValue> {
    // Connect to an echo server
    let ws =
        WebSocket::new("https://stream.binance.com:9443/ws/btcusdt@trade")?;
    // For small binary messages, like CBOR, Arraybuffer is more efficient than Blob handling
    ws.set_binary_type(web_sys::BinaryType::Arraybuffer);
    // create callback
    let cloned_ws = ws.clone();
    let onmessage_callback =
        Closure::<dyn FnMut(_)>::new(move |e: MessageEvent| {
            // Handle difference Text/Binary,...
            if let Ok(abuf) = e.data().dyn_into::<js_sys::ArrayBuffer>() {
                console_log!("message event, received arraybuffer: {:?}", abuf);
                let array = js_sys::Uint8Array::new(&abuf);
                let len = array.byte_length() as usize;
                console_log!(
                    "Arraybuffer received {}bytes: {:?}",
                    len,
                    array.to_vec()
                );
                // here you can for example use Serde Deserialize decode the message
                // for demo purposes we switch back to Blob-type and send off another binary message
                cloned_ws.set_binary_type(web_sys::BinaryType::Blob);
                match cloned_ws.send_with_u8_array(&[5, 6, 7, 8]) {
                    Ok(_) => console_log!("binary message successfully sent"),
                    Err(err) => {
                        console_log!("error sending message: {:?}", err)
                    }
                }
            } else if let Ok(blob) = e.data().dyn_into::<web_sys::Blob>() {
                console_log!("message event, received blob: {:?}", blob);
                // better alternative to juggling with FileReader is to use https://crates.io/crates/gloo-file
                let fr = web_sys::FileReader::new().unwrap();
                let fr_c = fr.clone();
                // create onLoadEnd callback
                let onloadend_cb = Closure::<dyn FnMut(_)>::new(
                    move |_e: web_sys::ProgressEvent| {
                        let array =
                            js_sys::Uint8Array::new(&fr_c.result().unwrap());
                        let len = array.byte_length() as usize;
                        console_log!(
                            "Blob received {}bytes: {:?}",
                            len,
                            array.to_vec()
                        );
                        // here you can for example use the received image/png data
                    },
                );
                fr.set_onloadend(Some(onloadend_cb.as_ref().unchecked_ref()));
                fr.read_as_array_buffer(&blob).expect("blob not readable");
                onloadend_cb.forget();
            } else if let Ok(txt) = e.data().dyn_into::<js_sys::JsString>() {
                console_log!("message event, received Text: {:?}", txt);
            } else {
                console_log!("message event, received Unknown: {:?}", e.data());
            }
        });
    // set message event handler on WebSocket
    ws.set_onmessage(Some(onmessage_callback.as_ref().unchecked_ref()));
    // forget the callback to keep it alive
    onmessage_callback.forget();

    let onerror_callback =
        Closure::<dyn FnMut(_)>::new(move |e: ErrorEvent| {
            console_log!("error event: {:?}", e);
        });
    ws.set_onerror(Some(onerror_callback.as_ref().unchecked_ref()));
    onerror_callback.forget();

    let onclose_callback = Closure::<dyn FnMut(web_sys::CloseEvent)>::wrap(
        Box::new(move |e: CloseEvent| {
            web_sys::console::log_1(
                &format!(
                    "Closed! Code: {}, Reason: {}, WasClean: {}",
                    e.code(),
                    e.reason(),
                    e.was_clean()
                )
                .into(),
            );
        }),
    );
    ws.set_onclose(Some(onclose_callback.as_ref().unchecked_ref()));
    onclose_callback.forget();

    Ok(())
}
```

**index.html**
```
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
</head>
<body>
  <script type="module">
    import init, { foo } from "./pkg/wasm_foo.js";

    async function run() {
      await init();   // loads wasm
    }

    run();    
  </script>
</body>
</html>
```