function _(element) { return document.getElementById(element); }

_('drag_drop').ondragover = function(event) { this.style.borderColor = '#333'; return false; }
_('drag_drop').ondragleave = function(event) { this.style.borderColor = '#ccc'; return false; }

_('drag_drop').ondrop = function(event) {
	event.preventDefault();
	var form_data = new FormData();
	var drop_files = event.dataTransfer.files;
	
	if (drop_files.length > 1) {
		alert("Only supports upload of one file");
		return;
	}
	form_data.append("movie_file", drop_files[0]);

	_('progress_bar').style.display = 'block';

	// 1. Start EventSource to monitor progress
	var source = new EventSource('progress');
	source.addEventListener('message', function(event) {
		if (event.data == "DONE") {
			source.close();
			_('progress_bar').style.display = 'none';
			
			// Start polling to ensure the image is fully ready and readable
			pollForImage();
		} else {
			var percent = Math.round(event.data);
			_('progress_bar_process').style.width = percent + '%';
			_('progress_bar_process').innerHTML = percent + '%';
		}
	});

	// 2. Perform the upload
	var ajax_request = new XMLHttpRequest();
	ajax_request.open("post", "upload");
	ajax_request.addEventListener('load', function(event) {
		if (ajax_request.status >= 400) {
			source.close();
			_('uploaded_image').innerHTML = '<div class="alert alert-danger"><b>Already running or error</div>';
			setTimeout(function() { _('uploaded_image').innerHTML = ''; }, 3000);
		}
	});
	ajax_request.send(form_data);
}

// Polling function to handle "file not ready yet" scenarios
function pollForImage() {
	var img = new Image();
	var newUrl = 'images/slitscan.png?' + Date.now();
	
	img.onload = function() {
		// Image loaded successfully and is not 0 bytes
		_('slitscan').src = newUrl;
		console.log("Slitscan loaded successfully.");
	};
	
	img.onerror = function() {
		// Image not ready or corrupted (0 bytes), retry in 1 second
		console.log("Slitscan not ready, retrying...");
		setTimeout(pollForImage, 1000);
	};
	
	img.src = newUrl;
}
