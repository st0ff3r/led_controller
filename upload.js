var source; // Global variable for EventSource

function _(element) {
	return document.getElementById(element);
}

// Trigger hidden file input when clicking the drag & drop area
_('drag_drop').onclick = function(event) {
	if (event.target.id === 'drag_drop' || event.target.tagName === 'DIV') {
		_('file_input').click();
	}
};

// Handle file selection via standard file dialog
_('file_input').onchange = function(event) {
	var select_files = event.target.files;
	if (select_files.length > 0) {
		handleFileUpload(select_files[0]);
	}
};

// Drag and Drop event handlers
_('drag_drop').ondragover = function(event) {
	event.preventDefault();
	this.style.borderColor = '#333';
	return false;
};

_('drag_drop').ondragleave = function(event) {
	this.style.borderColor = '#ccc';
	return false;
};

_('drag_drop').ondrop = function(event) {
	event.preventDefault();
	var drop_files = event.dataTransfer.files;
	
	if (drop_files.length <= 1) {
		handleFileUpload(drop_files[0]);
	} else {
		showUploadError('<div class="alert alert-danger"><b>only supports upload of one file</div>');
	}
};

// Core Upload and Progress Handler Function
function handleFileUpload(file) {
	var form_data = new FormData();
	form_data.append("movie_file", file);

	_('progress_bar').style.display = 'block';
	var ajax_request = new XMLHttpRequest();
	ajax_request.open("post", "upload");

	ajax_request.addEventListener('error', function(event) {
		console.log("An error occurred while attempting to connect.");
		resetProgressBar();
	});

	ajax_request.addEventListener('load', function(event) {
		if (ajax_request.status >= 400) {
			showUploadError('<div class="alert alert-danger"><b>already running</div>');
		}
	});
	
	// Server-Sent Events for status tracking
	source = new EventSource('progress');
	
	source.addEventListener('error', function(event) {
		console.log("SSE Connection closed or error.");
		source.close();
		resetProgressBar();
	});

	source.addEventListener('message', function(event) {
		var data = event.data;
		console.log("Status update: " + data);
		
		// Map numerical status to UI states
		if (data == "50.0") {
			_('progress_bar_process').style.width = '50%';
			_('progress_bar_process').innerHTML = 'Processing...';
		} 
		else if (data == "100.0") {
			_('progress_bar_process').style.width = '100%';
			_('progress_bar_process').innerHTML = 'Ready';
			
			// Close stream and finalize UI
			source.close();
			setTimeout(function() {
				resetProgressBar();
				_('slitscan').src = 'images/slitscan.png?' + Date.now();
			}, 1500); // 1.5s delay so user sees "Ready"
		} 
		else if (data == "0.0") {
			source.close();
			resetProgressBar();
		} 
		else if (data == "ERROR") {
			source.close();
			resetProgressBar();
			showUploadError('<div class="alert alert-danger"><b>server side processing failed</div>');
		}
	}, false);

	ajax_request.send(form_data);
}

// Helper function to reset UI progress
function resetProgressBar() {
	_('progress_bar').style.display = 'none';
	_('progress_bar_process').style.width = '0%';
	_('progress_bar_process').innerHTML = '';
	_('drag_drop').style.borderColor = '#ccc';
	_('file_input').value = ''; 
}

// Helper function to show errors
function showUploadError(errorMessage) {
	_('uploaded_image').style.display = 'block';
	_('uploaded_image').innerHTML = errorMessage;
	_('drag_drop').style.borderColor = '#ccc';

	setTimeout(function() {
		_('uploaded_image').innerHTML = '';
	}, 3000);
}
