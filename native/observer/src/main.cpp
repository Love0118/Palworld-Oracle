#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <system_error>
#include <thread>
#include <utility>
#include <vector>

#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

namespace {

using SteadyClock = std::chrono::steady_clock;

constexpr std::string_view kDefaultCgroupPath =
    "/sys/fs/cgroup/system.slice/palworld.service";
constexpr std::size_t kHistoryLimit = 360U;
constexpr std::size_t kMaxHttpResponse = 1024U * 1024U;
constexpr int kSocketTimeoutSeconds = 5;
constexpr auto kMinimumMemoryTrendWindow = std::chrono::minutes(5);

volatile std::sig_atomic_t g_stop_requested = 0;

extern "C" void handle_signal(int) { g_stop_requested = 1; }

struct Config {
  std::string rest_host{"127.0.0.1"};
  std::string rest_port{"8212"};
  std::string rest_base_path{"/v1/api"};
  std::string rest_user{"admin"};
  std::filesystem::path credential_path;
  std::filesystem::path output_path{
      "/var/lib/palworld-observer/palworld.prom"};
  std::chrono::seconds interval{10};
};

struct ServerMetrics {
  double server_fps{};
  double server_frame_time{};
  double current_player_num{};
  double max_player_num{};
  double uptime{};
};

struct CgroupMetrics {
  std::uint64_t memory_current{};
  std::uint64_t anonymous_memory{};
  std::uint64_t cpu_usage_usec{};
  std::uint64_t oom{};
  std::uint64_t oom_kill{};
};

struct HistorySample {
  SteadyClock::time_point time;
  double frame_time_ms{};
  double anonymous_memory_mib{};
};

struct DerivedMetrics {
  std::optional<double> cpu_percent;
  double frame_time_p50_ms{};
  double frame_time_p95_ms{};
  double frame_time_p99_ms{};
  std::optional<double> anonymous_memory_mib_per_hour;
};

std::string get_environment(const char* name, std::string fallback) {
  const char* value = std::getenv(name);
  if (value == nullptr || *value == '\0') {
    return fallback;
  }
  return value;
}

bool contains_control_character(std::string_view value) {
  return std::any_of(value.begin(), value.end(), [](const char character) {
    const auto byte = static_cast<unsigned char>(character);
    return byte < 0x20U || byte == 0x7fU;
  });
}

std::uint64_t parse_unsigned(std::string_view input,
                             std::string_view description) {
  if (input.empty()) {
    throw std::runtime_error(std::string(description) + " is empty");
  }
  std::uint64_t value = 0U;
  for (const char character : input) {
    if (character < '0' || character > '9') {
      throw std::runtime_error(std::string(description) +
                               " is not an unsigned integer");
    }
    const auto digit = static_cast<std::uint64_t>(character - '0');
    if (value > (std::numeric_limits<std::uint64_t>::max() - digit) / 10U) {
      throw std::runtime_error(std::string(description) + " is too large");
    }
    value = value * 10U + digit;
  }
  return value;
}

Config load_config() {
  Config config;
  config.rest_host = get_environment("PALWORLD_REST_HOST", config.rest_host);
  config.rest_port = get_environment("PALWORLD_REST_PORT", config.rest_port);
  config.rest_base_path =
      get_environment("PALWORLD_REST_BASE_PATH", config.rest_base_path);
  config.rest_user = get_environment("PALWORLD_REST_USER", config.rest_user);

  const std::string interval =
      get_environment("PALWORLD_OBSERVER_INTERVAL_SECONDS", "10");
  const std::uint64_t interval_seconds =
      parse_unsigned(interval, "PALWORLD_OBSERVER_INTERVAL_SECONDS");
  if (interval_seconds == 0U ||
      interval_seconds >
          static_cast<std::uint64_t>(std::numeric_limits<int>::max())) {
    throw std::runtime_error(
        "PALWORLD_OBSERVER_INTERVAL_SECONDS must be between 1 and INT_MAX");
  }
  config.interval = std::chrono::seconds(interval_seconds);

  const std::string output = get_environment(
      "PALWORLD_OBSERVER_OUTPUT", config.output_path.string());
  config.output_path = output;

  const std::string credentials_directory =
      get_environment("CREDENTIALS_DIRECTORY", "");
  if (credentials_directory.empty()) {
    throw std::runtime_error("CREDENTIALS_DIRECTORY is not set");
  }
  config.credential_path =
      std::filesystem::path(credentials_directory) / "admin-password";

  if (config.rest_host.empty() || contains_control_character(config.rest_host)) {
    throw std::runtime_error("PALWORLD_REST_HOST is invalid");
  }
  const std::uint64_t port =
      parse_unsigned(config.rest_port, "PALWORLD_REST_PORT");
  if (port == 0U || port > 65535U) {
    throw std::runtime_error("PALWORLD_REST_PORT must be between 1 and 65535");
  }
  if (config.rest_base_path.empty() || config.rest_base_path.front() != '/' ||
      contains_control_character(config.rest_base_path) ||
      config.rest_base_path.find(' ') != std::string::npos) {
    throw std::runtime_error("PALWORLD_REST_BASE_PATH is invalid");
  }
  if (config.rest_user.empty() || contains_control_character(config.rest_user) ||
      config.rest_user.find(':') != std::string::npos) {
    throw std::runtime_error("PALWORLD_REST_USER is invalid");
  }
  if (config.output_path.empty()) {
    throw std::runtime_error("PALWORLD_OBSERVER_OUTPUT is empty");
  }
  return config;
}

std::string read_text_file(const std::filesystem::path& path,
                           std::size_t maximum_size = 64U * 1024U) {
  std::ifstream input(path, std::ios::binary);
  if (!input) {
    throw std::runtime_error("cannot open " + path.string());
  }
  std::string contents;
  std::array<char, 4096U> buffer{};
  while (input) {
    input.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
    const std::streamsize count = input.gcount();
    if (count > 0) {
      const auto unsigned_count = static_cast<std::size_t>(count);
      if (contents.size() > maximum_size - unsigned_count) {
        throw std::runtime_error(path.string() + " exceeds the size limit");
      }
      contents.append(buffer.data(), unsigned_count);
    }
  }
  if (!input.eof()) {
    throw std::runtime_error("cannot read " + path.string());
  }
  return contents;
}

std::string read_password(const std::filesystem::path& path) {
  std::string password = read_text_file(path, 16U * 1024U);
  while (!password.empty() &&
         (password.back() == '\n' || password.back() == '\r')) {
    password.pop_back();
  }
  if (password.empty()) {
    throw std::runtime_error("admin password credential is empty");
  }
  return password;
}

std::string base64_encode(std::string_view input) {
  static constexpr std::string_view alphabet =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string output;
  output.reserve(((input.size() + 2U) / 3U) * 4U);
  std::size_t position = 0U;
  while (position + 3U <= input.size()) {
    const auto first = static_cast<unsigned char>(input[position]);
    const auto second = static_cast<unsigned char>(input[position + 1U]);
    const auto third = static_cast<unsigned char>(input[position + 2U]);
    output.push_back(alphabet[first >> 2U]);
    output.push_back(alphabet[((first & 0x03U) << 4U) | (second >> 4U)]);
    output.push_back(alphabet[((second & 0x0fU) << 2U) | (third >> 6U)]);
    output.push_back(alphabet[third & 0x3fU]);
    position += 3U;
  }
  const std::size_t remaining = input.size() - position;
  if (remaining == 1U) {
    const auto first = static_cast<unsigned char>(input[position]);
    output.push_back(alphabet[first >> 2U]);
    output.push_back(alphabet[(first & 0x03U) << 4U]);
    output.append("==");
  } else if (remaining == 2U) {
    const auto first = static_cast<unsigned char>(input[position]);
    const auto second = static_cast<unsigned char>(input[position + 1U]);
    output.push_back(alphabet[first >> 2U]);
    output.push_back(alphabet[((first & 0x03U) << 4U) | (second >> 4U)]);
    output.push_back(alphabet[(second & 0x0fU) << 2U]);
    output.push_back('=');
  }
  return output;
}

class FileDescriptor {
 public:
  explicit FileDescriptor(int descriptor = -1) : descriptor_(descriptor) {}
  ~FileDescriptor() {
    if (descriptor_ >= 0) {
      static_cast<void>(::close(descriptor_));
    }
  }
  FileDescriptor(const FileDescriptor&) = delete;
  FileDescriptor& operator=(const FileDescriptor&) = delete;
  FileDescriptor(FileDescriptor&& other) noexcept
      : descriptor_(std::exchange(other.descriptor_, -1)) {}
  FileDescriptor& operator=(FileDescriptor&& other) noexcept {
    if (this != &other) {
      if (descriptor_ >= 0) {
        static_cast<void>(::close(descriptor_));
      }
      descriptor_ = std::exchange(other.descriptor_, -1);
    }
    return *this;
  }
  [[nodiscard]] int get() const { return descriptor_; }
  [[nodiscard]] bool valid() const { return descriptor_ >= 0; }

 private:
  int descriptor_;
};

class AddressInfo {
 public:
  explicit AddressInfo(addrinfo* addresses) : addresses_(addresses) {}
  ~AddressInfo() {
    if (addresses_ != nullptr) {
      ::freeaddrinfo(addresses_);
    }
  }
  AddressInfo(const AddressInfo&) = delete;
  AddressInfo& operator=(const AddressInfo&) = delete;
  [[nodiscard]] addrinfo* get() const { return addresses_; }

 private:
  addrinfo* addresses_;
};

void write_all(int descriptor, std::string_view data) {
  std::size_t written = 0U;
  while (written < data.size()) {
    const ssize_t result =
        ::write(descriptor, data.data() + written, data.size() - written);
    if (result < 0 && errno == EINTR) {
      if (g_stop_requested != 0) {
        throw std::runtime_error("write interrupted by shutdown");
      }
      continue;
    }
    if (result <= 0) {
      throw std::runtime_error("socket write failed: " +
                               std::string(std::strerror(errno)));
    }
    written += static_cast<std::size_t>(result);
  }
}

FileDescriptor connect_to_server(const Config& config) {
  addrinfo hints{};
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_protocol = IPPROTO_TCP;
  addrinfo* raw_addresses = nullptr;
  const int lookup_result = ::getaddrinfo(config.rest_host.c_str(),
                                          config.rest_port.c_str(), &hints,
                                          &raw_addresses);
  if (lookup_result != 0) {
    throw std::runtime_error("REST address lookup failed: " +
                             std::string(::gai_strerror(lookup_result)));
  }
  AddressInfo addresses(raw_addresses);
  std::string last_error = "no usable REST address";
  for (addrinfo* address = addresses.get(); address != nullptr;
       address = address->ai_next) {
    FileDescriptor socket_descriptor(
        ::socket(address->ai_family, address->ai_socktype, address->ai_protocol));
    if (!socket_descriptor.valid()) {
      last_error = std::strerror(errno);
      continue;
    }
    const timeval timeout{kSocketTimeoutSeconds, 0};
    if (::setsockopt(socket_descriptor.get(), SOL_SOCKET, SO_RCVTIMEO, &timeout,
                     sizeof(timeout)) != 0 ||
        ::setsockopt(socket_descriptor.get(), SOL_SOCKET, SO_SNDTIMEO, &timeout,
                     sizeof(timeout)) != 0) {
      last_error = std::strerror(errno);
      continue;
    }
    if (::connect(socket_descriptor.get(), address->ai_addr,
                  address->ai_addrlen) == 0) {
      return socket_descriptor;
    }
    last_error = std::strerror(errno);
  }
  throw std::runtime_error("REST connection failed: " + last_error);
}

std::string decode_chunked_body(std::string_view encoded) {
  std::string decoded;
  std::size_t position = 0U;
  while (true) {
    const std::size_t line_end = encoded.find("\r\n", position);
    if (line_end == std::string_view::npos) {
      throw std::runtime_error("malformed chunked REST response");
    }
    std::string_view size_text = encoded.substr(position, line_end - position);
    const std::size_t extension = size_text.find(';');
    if (extension != std::string_view::npos) {
      size_text = size_text.substr(0U, extension);
    }
    if (size_text.empty()) {
      throw std::runtime_error("empty HTTP chunk size");
    }
    std::uint64_t chunk_size = 0U;
    for (const char character : size_text) {
      unsigned int digit = 0U;
      if (character >= '0' && character <= '9') {
        digit = static_cast<unsigned int>(character - '0');
      } else if (character >= 'a' && character <= 'f') {
        digit = static_cast<unsigned int>(character - 'a') + 10U;
      } else if (character >= 'A' && character <= 'F') {
        digit = static_cast<unsigned int>(character - 'A') + 10U;
      } else {
        throw std::runtime_error("invalid HTTP chunk size");
      }
      if (chunk_size >
          (std::numeric_limits<std::uint64_t>::max() - digit) / 16U) {
        throw std::runtime_error("HTTP chunk size overflow");
      }
      chunk_size = chunk_size * 16U + digit;
    }
    position = line_end + 2U;
    if (chunk_size == 0U) {
      return decoded;
    }
    if (chunk_size > kMaxHttpResponse ||
        position > encoded.size() ||
        chunk_size > encoded.size() - position) {
      throw std::runtime_error("truncated or oversized HTTP chunk");
    }
    const auto chunk_length = static_cast<std::size_t>(chunk_size);
    if (decoded.size() > kMaxHttpResponse - chunk_length) {
      throw std::runtime_error("decoded REST response exceeds the size limit");
    }
    decoded.append(encoded.substr(position, chunk_length));
    position += chunk_length;
    if (position + 2U > encoded.size() ||
        encoded.substr(position, 2U) != "\r\n") {
      throw std::runtime_error("malformed HTTP chunk terminator");
    }
    position += 2U;
  }
}

std::string lower_ascii(std::string input) {
  std::transform(input.begin(), input.end(), input.begin(), [](const char value) {
    if (value >= 'A' && value <= 'Z') {
      return static_cast<char>(value - 'A' + 'a');
    }
    return value;
  });
  return input;
}

std::string parse_http_response(std::string response) {
  const std::size_t headers_end = response.find("\r\n\r\n");
  if (headers_end == std::string::npos) {
    throw std::runtime_error("REST response has no complete HTTP headers");
  }
  const std::size_t status_end = response.find("\r\n");
  if (status_end == std::string::npos || status_end > headers_end) {
    throw std::runtime_error("REST response has no HTTP status line");
  }
  const std::string_view status_line(response.data(), status_end);
  const std::size_t first_space = status_line.find(' ');
  if (first_space == std::string_view::npos || first_space + 4U > status_line.size()) {
    throw std::runtime_error("REST response has a malformed HTTP status");
  }
  const std::string_view status_code = status_line.substr(first_space + 1U, 3U);
  if (status_code != "200") {
    throw std::runtime_error("REST endpoint returned HTTP " +
                             std::string(status_code));
  }

  bool chunked = false;
  std::optional<std::uint64_t> content_length;
  std::size_t header_position = status_end + 2U;
  while (header_position < headers_end) {
    const std::size_t line_end = response.find("\r\n", header_position);
    if (line_end == std::string::npos || line_end > headers_end) {
      throw std::runtime_error("malformed REST response header");
    }
    const std::string line = response.substr(header_position,
                                             line_end - header_position);
    const std::size_t colon = line.find(':');
    if (colon != std::string::npos) {
      const std::string name = lower_ascii(line.substr(0U, colon));
      std::string value = line.substr(colon + 1U);
      const std::size_t first = value.find_first_not_of(" \t");
      value = first == std::string::npos ? "" : value.substr(first);
      const std::size_t last = value.find_last_not_of(" \t");
      if (last != std::string::npos) {
        value.resize(last + 1U);
      }
      if (name == "transfer-encoding" &&
          lower_ascii(value).find("chunked") != std::string::npos) {
        chunked = true;
      } else if (name == "content-length") {
        content_length = parse_unsigned(value, "HTTP Content-Length");
      }
    }
    header_position = line_end + 2U;
  }

  std::string body = response.substr(headers_end + 4U);
  if (chunked) {
    return decode_chunked_body(body);
  }
  if (content_length.has_value()) {
    if (*content_length > kMaxHttpResponse ||
        *content_length > body.size()) {
      throw std::runtime_error("truncated or oversized REST response body");
    }
    body.resize(static_cast<std::size_t>(*content_length));
  }
  return body;
}

std::string fetch_metrics_json(const Config& config,
                               std::string_view password) {
  std::string path = config.rest_base_path;
  if (path.back() != '/') {
    path.push_back('/');
  }
  path.append("metrics");
  const std::string authorization =
      base64_encode(config.rest_user + ":" + std::string(password));
  const std::string request =
      "GET " + path + " HTTP/1.1\r\nHost: " + config.rest_host + ":" +
      config.rest_port + "\r\nAuthorization: Basic " + authorization +
      "\r\nAccept: application/json\r\nConnection: close\r\n\r\n";

  FileDescriptor socket_descriptor = connect_to_server(config);
  write_all(socket_descriptor.get(), request);
  std::string response;
  std::array<char, 8192U> buffer{};
  while (true) {
    const ssize_t count =
        ::read(socket_descriptor.get(), buffer.data(), buffer.size());
    if (count < 0 && errno == EINTR) {
      if (g_stop_requested != 0) {
        throw std::runtime_error("REST read interrupted by shutdown");
      }
      continue;
    }
    if (count < 0) {
      throw std::runtime_error("REST response read failed: " +
                               std::string(std::strerror(errno)));
    }
    if (count == 0) {
      break;
    }
    const auto unsigned_count = static_cast<std::size_t>(count);
    if (response.size() > kMaxHttpResponse - unsigned_count) {
      throw std::runtime_error("REST response exceeds the size limit");
    }
    response.append(buffer.data(), unsigned_count);
  }
  return parse_http_response(std::move(response));
}

class JsonCursor {
 public:
  explicit JsonCursor(std::string_view input) : input_(input) {}

  ServerMetrics parse_metrics() {
    skip_whitespace();
    expect('{');
    std::optional<double> server_fps;
    std::optional<double> server_frame_time;
    std::optional<double> current_player_num;
    std::optional<double> max_player_num;
    std::optional<double> uptime;
    skip_whitespace();
    if (consume('}')) {
      throw std::runtime_error("REST metrics object is empty");
    }
    while (true) {
      const std::string key = parse_string();
      skip_whitespace();
      expect(':');
      skip_whitespace();
      if (key == "serverfps") {
        server_fps = parse_number();
      } else if (key == "serverframetime") {
        server_frame_time = parse_number();
      } else if (key == "currentplayernum") {
        current_player_num = parse_number();
      } else if (key == "maxplayernum") {
        max_player_num = parse_number();
      } else if (key == "uptime") {
        uptime = parse_number();
      } else {
        skip_value();
      }
      skip_whitespace();
      if (consume('}')) {
        break;
      }
      expect(',');
      skip_whitespace();
    }
    skip_whitespace();
    if (position_ != input_.size()) {
      throw std::runtime_error("trailing data after REST metrics JSON");
    }
    if (!server_fps.has_value() || !server_frame_time.has_value() ||
        !current_player_num.has_value() || !max_player_num.has_value() ||
        !uptime.has_value()) {
      throw std::runtime_error("REST metrics JSON is missing required fields");
    }
    if (*server_fps < 0.0 || *server_frame_time < 0.0 ||
        *current_player_num < 0.0 || *max_player_num < 0.0 ||
        *uptime < 0.0 || *current_player_num > *max_player_num) {
      throw std::runtime_error("REST metrics JSON contains invalid values");
    }
    return {*server_fps, *server_frame_time, *current_player_num,
            *max_player_num, *uptime};
  }

 private:
  void skip_whitespace() {
    while (position_ < input_.size()) {
      const char character = input_[position_];
      if (character != ' ' && character != '\t' && character != '\r' &&
          character != '\n') {
        return;
      }
      ++position_;
    }
  }

  bool consume(char expected) {
    if (position_ < input_.size() && input_[position_] == expected) {
      ++position_;
      return true;
    }
    return false;
  }

  void expect(char expected) {
    if (!consume(expected)) {
      throw std::runtime_error(std::string("expected '") + expected +
                               "' in REST metrics JSON");
    }
  }

  std::string parse_string() {
    expect('"');
    std::string result;
    while (position_ < input_.size()) {
      const char character = input_[position_++];
      if (character == '"') {
        return result;
      }
      if (static_cast<unsigned char>(character) < 0x20U) {
        throw std::runtime_error("control character in REST JSON string");
      }
      if (character != '\\') {
        result.push_back(character);
        continue;
      }
      if (position_ >= input_.size()) {
        throw std::runtime_error("truncated escape in REST JSON string");
      }
      const char escaped = input_[position_++];
      switch (escaped) {
        case '"':
        case '\\':
        case '/':
          result.push_back(escaped);
          break;
        case 'b':
          result.push_back('\b');
          break;
        case 'f':
          result.push_back('\f');
          break;
        case 'n':
          result.push_back('\n');
          break;
        case 'r':
          result.push_back('\r');
          break;
        case 't':
          result.push_back('\t');
          break;
        case 'u':
          if (position_ + 4U > input_.size()) {
            throw std::runtime_error("truncated Unicode escape in REST JSON");
          }
          for (std::size_t index = 0U; index < 4U; ++index) {
            const char hex = input_[position_ + index];
            const bool valid = (hex >= '0' && hex <= '9') ||
                               (hex >= 'a' && hex <= 'f') ||
                               (hex >= 'A' && hex <= 'F');
            if (!valid) {
              throw std::runtime_error("invalid Unicode escape in REST JSON");
            }
          }
          result.append(input_.substr(position_ - 2U, 6U));
          position_ += 4U;
          break;
        default:
          throw std::runtime_error("invalid escape in REST JSON string");
      }
    }
    throw std::runtime_error("unterminated REST JSON string");
  }

  double parse_number() {
    const std::size_t start = position_;
    static_cast<void>(consume('-'));
    if (consume('0')) {
      if (position_ < input_.size() && input_[position_] >= '0' &&
          input_[position_] <= '9') {
        throw std::runtime_error("leading zero in REST JSON number");
      }
    } else {
      if (position_ >= input_.size() || input_[position_] < '1' ||
          input_[position_] > '9') {
        throw std::runtime_error("invalid REST JSON number");
      }
      while (position_ < input_.size() && input_[position_] >= '0' &&
             input_[position_] <= '9') {
        ++position_;
      }
    }
    if (consume('.')) {
      if (position_ >= input_.size() || input_[position_] < '0' ||
          input_[position_] > '9') {
        throw std::runtime_error("invalid fraction in REST JSON number");
      }
      while (position_ < input_.size() && input_[position_] >= '0' &&
             input_[position_] <= '9') {
        ++position_;
      }
    }
    if (position_ < input_.size() &&
        (input_[position_] == 'e' || input_[position_] == 'E')) {
      ++position_;
      if (position_ < input_.size() &&
          (input_[position_] == '+' || input_[position_] == '-')) {
        ++position_;
      }
      if (position_ >= input_.size() || input_[position_] < '0' ||
          input_[position_] > '9') {
        throw std::runtime_error("invalid exponent in REST JSON number");
      }
      while (position_ < input_.size() && input_[position_] >= '0' &&
             input_[position_] <= '9') {
        ++position_;
      }
    }
    const std::string text(input_.substr(start, position_ - start));
    char* end = nullptr;
    errno = 0;
    const double value = std::strtod(text.c_str(), &end);
    if (errno == ERANGE || end == nullptr ||
        end != text.c_str() + static_cast<std::ptrdiff_t>(text.size()) ||
        !std::isfinite(value)) {
      throw std::runtime_error("REST JSON number is out of range");
    }
    return value;
  }

  void skip_literal(std::string_view literal) {
    if (input_.substr(position_, literal.size()) != literal) {
      throw std::runtime_error("invalid literal in REST JSON");
    }
    position_ += literal.size();
  }

  void skip_value() {
    skip_whitespace();
    if (position_ >= input_.size()) {
      throw std::runtime_error("missing value in REST JSON");
    }
    const char character = input_[position_];
    if (character == '"') {
      static_cast<void>(parse_string());
    } else if (character == '{') {
      ++position_;
      skip_whitespace();
      if (consume('}')) {
        return;
      }
      while (true) {
        static_cast<void>(parse_string());
        skip_whitespace();
        expect(':');
        skip_value();
        skip_whitespace();
        if (consume('}')) {
          return;
        }
        expect(',');
        skip_whitespace();
      }
    } else if (character == '[') {
      ++position_;
      skip_whitespace();
      if (consume(']')) {
        return;
      }
      while (true) {
        skip_value();
        skip_whitespace();
        if (consume(']')) {
          return;
        }
        expect(',');
        skip_whitespace();
      }
    } else if (character == 't') {
      skip_literal("true");
    } else if (character == 'f') {
      skip_literal("false");
    } else if (character == 'n') {
      skip_literal("null");
    } else {
      static_cast<void>(parse_number());
    }
  }

  std::string_view input_;
  std::size_t position_{0U};
};

ServerMetrics parse_server_metrics(std::string_view json) {
  return JsonCursor(json).parse_metrics();
}

std::uint64_t parse_single_counter(const std::filesystem::path& path) {
  std::string text = read_text_file(path, 4096U);
  const std::size_t end = text.find_first_of(" \t\r\n");
  if (end != std::string::npos) {
    text.resize(end);
  }
  return parse_unsigned(text, path.string());
}

std::uint64_t parse_named_counter(const std::filesystem::path& path,
                                  std::string_view wanted_name) {
  std::istringstream input(read_text_file(path));
  std::string name;
  std::string value;
  while (input >> name >> value) {
    if (name == wanted_name) {
      return parse_unsigned(value, path.string() + " " + name);
    }
  }
  throw std::runtime_error("counter " + std::string(wanted_name) +
                           " is missing from " + path.string());
}

CgroupMetrics read_cgroup_metrics() {
  const std::filesystem::path root(kDefaultCgroupPath);
  return {
      parse_single_counter(root / "memory.current"),
      parse_named_counter(root / "memory.stat", "anon"),
      parse_named_counter(root / "cpu.stat", "usage_usec"),
      parse_named_counter(root / "memory.events", "oom"),
      parse_named_counter(root / "memory.events", "oom_kill"),
  };
}

double percentile(std::vector<double> values, double percentile_value) {
  if (values.empty()) {
    throw std::runtime_error("cannot calculate a percentile of no samples");
  }
  std::sort(values.begin(), values.end());
  if (values.size() == 1U) {
    return values.front();
  }
  const double rank =
      percentile_value * static_cast<double>(values.size() - 1U);
  const auto lower_index = static_cast<std::size_t>(std::floor(rank));
  const auto upper_index = static_cast<std::size_t>(std::ceil(rank));
  const double fraction = rank - static_cast<double>(lower_index);
  return values[lower_index] * (1.0 - fraction) +
         values[upper_index] * fraction;
}

std::optional<double> calculate_anonymous_memory_slope(
    const std::vector<HistorySample>& history) {
  if (history.size() < 2U) {
    return std::nullopt;
  }
  if (history.back().time - history.front().time < kMinimumMemoryTrendWindow) {
    return std::nullopt;
  }
  const auto origin = history.front().time;
  double sum_x = 0.0;
  double sum_y = 0.0;
  for (const HistorySample& sample : history) {
    sum_x += std::chrono::duration<double>(sample.time - origin).count();
    sum_y += sample.anonymous_memory_mib;
  }
  const double count = static_cast<double>(history.size());
  const double mean_x = sum_x / count;
  const double mean_y = sum_y / count;
  double numerator = 0.0;
  double denominator = 0.0;
  for (const HistorySample& sample : history) {
    const double x =
        std::chrono::duration<double>(sample.time - origin).count() - mean_x;
    numerator += x * (sample.anonymous_memory_mib - mean_y);
    denominator += x * x;
  }
  if (denominator <= std::numeric_limits<double>::epsilon()) {
    return std::nullopt;
  }
  return numerator / denominator * 3600.0;
}

DerivedMetrics derive_metrics(
    const std::vector<HistorySample>& history,
    const CgroupMetrics& current_cgroup,
    const std::optional<std::pair<SteadyClock::time_point, std::uint64_t>>&
        previous_cpu,
    SteadyClock::time_point now) {
  std::optional<double> cpu_percent;
  if (previous_cpu.has_value() &&
      current_cgroup.cpu_usage_usec >= previous_cpu->second) {
    const double elapsed_usec =
        std::chrono::duration<double, std::micro>(now - previous_cpu->first)
            .count();
    if (elapsed_usec > 0.0) {
      cpu_percent =
          static_cast<double>(current_cgroup.cpu_usage_usec -
                              previous_cpu->second) /
          elapsed_usec * 100.0;
    }
  }
  std::vector<double> frame_times;
  frame_times.reserve(history.size());
  for (const HistorySample& sample : history) {
    frame_times.push_back(sample.frame_time_ms);
  }
  return {cpu_percent,
          percentile(frame_times, 0.50),
          percentile(frame_times, 0.95),
          percentile(frame_times, 0.99),
          calculate_anonymous_memory_slope(history)};
}

std::string utc_timestamp() {
  const std::time_t now = std::time(nullptr);
  std::tm utc{};
  if (::gmtime_r(&now, &utc) == nullptr) {
    throw std::runtime_error("cannot convert the current UTC time");
  }
  std::array<char, 32U> buffer{};
  if (std::strftime(buffer.data(), buffer.size(), "%Y-%m-%dT%H:%M:%SZ", &utc) ==
      0U) {
    throw std::runtime_error("cannot format the current UTC time");
  }
  return buffer.data();
}

void append_optional_json_number(std::ostringstream& output,
                                 const std::optional<double>& value) {
  if (value.has_value()) {
    output << *value;
  } else {
    output << "null";
  }
}

std::string make_json_line(const ServerMetrics& server,
                           const CgroupMetrics& cgroup,
                           const DerivedMetrics& derived,
                           std::size_t history_size) {
  std::ostringstream output;
  output << std::setprecision(12) << "{\"timestamp\":\"" << utc_timestamp()
         << "\",\"serverfps\":" << server.server_fps
         << ",\"serverframetime\":" << server.server_frame_time
         << ",\"currentplayernum\":" << server.current_player_num
         << ",\"maxplayernum\":" << server.max_player_num
         << ",\"uptime\":" << server.uptime << ",\"cpu_percent\":";
  append_optional_json_number(output, derived.cpu_percent);
  output << ",\"cgroup_memory_bytes\":" << cgroup.memory_current
         << ",\"anonymous_memory_bytes\":" << cgroup.anonymous_memory
         << ",\"oom\":" << cgroup.oom << ",\"oom_kill\":" << cgroup.oom_kill
         << ",\"window_samples\":" << history_size
         << ",\"frametime_p50_ms\":" << derived.frame_time_p50_ms
         << ",\"frametime_p95_ms\":" << derived.frame_time_p95_ms
         << ",\"frametime_p99_ms\":" << derived.frame_time_p99_ms
         << ",\"anonymous_memory_mib_per_hour\":";
  append_optional_json_number(output,
                              derived.anonymous_memory_mib_per_hour);
  output << '}';
  return output.str();
}

void append_metric(std::ostringstream& output, std::string_view name,
                   std::string_view help, std::string_view type, double value) {
  output << "# HELP " << name << ' ' << help << '\n';
  output << "# TYPE " << name << ' ' << type << '\n';
  output << name << ' ' << std::setprecision(12) << value << '\n';
}

std::string make_prometheus_text(const ServerMetrics& server,
                                 const CgroupMetrics& cgroup,
                                 const DerivedMetrics& derived,
                                 std::size_t history_size) {
  std::ostringstream output;
  append_metric(output, "palworld_server_fps", "Palworld server frames per second.",
                "gauge", server.server_fps);
  append_metric(output, "palworld_server_frame_time_milliseconds",
                "Palworld server frame time in milliseconds.", "gauge",
                server.server_frame_time);
  append_metric(output, "palworld_current_players",
                "Current Palworld player count.", "gauge",
                server.current_player_num);
  append_metric(output, "palworld_max_players", "Configured maximum player count.",
                "gauge", server.max_player_num);
  append_metric(output, "palworld_uptime_seconds", "Palworld server uptime.",
                "gauge", server.uptime);
  if (derived.cpu_percent.has_value()) {
    append_metric(output, "palworld_cgroup_cpu_percent",
                  "Palworld service CPU use; 100 percent is one logical CPU.",
                  "gauge", *derived.cpu_percent);
  }
  append_metric(output, "palworld_cgroup_memory_bytes",
                "Current Palworld service cgroup memory use.", "gauge",
                static_cast<double>(cgroup.memory_current));
  append_metric(output, "palworld_cgroup_anonymous_memory_bytes",
                "Anonymous memory charged to the Palworld service cgroup.",
                "gauge", static_cast<double>(cgroup.anonymous_memory));
  append_metric(output, "palworld_cgroup_oom_total",
                "Palworld service cgroup OOM event count.", "counter",
                static_cast<double>(cgroup.oom));
  append_metric(output, "palworld_cgroup_oom_kill_total",
                "Palworld service cgroup OOM kill count.", "counter",
                static_cast<double>(cgroup.oom_kill));
  append_metric(output, "palworld_observer_window_samples",
                "Samples currently retained by the observer.", "gauge",
                static_cast<double>(history_size));
  append_metric(output, "palworld_frame_time_p50_milliseconds",
                "Frame time p50 over the retained sample window.", "gauge",
                derived.frame_time_p50_ms);
  append_metric(output, "palworld_frame_time_p95_milliseconds",
                "Frame time p95 over the retained sample window.", "gauge",
                derived.frame_time_p95_ms);
  append_metric(output, "palworld_frame_time_p99_milliseconds",
                "Frame time p99 over the retained sample window.", "gauge",
                derived.frame_time_p99_ms);
  if (derived.anonymous_memory_mib_per_hour.has_value()) {
    append_metric(
        output, "palworld_anonymous_memory_trend_mib_per_hour",
        "Linear anonymous-memory slope over the retained sample window.",
        "gauge", *derived.anonymous_memory_mib_per_hour);
  }
  append_metric(output, "palworld_observer_last_success_unixtime",
                "Unix timestamp of the last successful observation.", "gauge",
                static_cast<double>(std::time(nullptr)));
  return output.str();
}

void atomic_write(const std::filesystem::path& destination,
                  std::string_view contents) {
  const std::filesystem::path directory = destination.parent_path();
  if (directory.empty()) {
    throw std::runtime_error("Prometheus output path has no parent directory");
  }
  std::error_code error;
  if (!std::filesystem::is_directory(directory, error)) {
    throw std::runtime_error("Prometheus output directory is unavailable: " +
                             directory.string());
  }
  std::string template_path = destination.string() + ".tmp.XXXXXX";
  std::vector<char> writable_template(template_path.begin(),
                                      template_path.end());
  writable_template.push_back('\0');
  FileDescriptor temporary(::mkstemp(writable_template.data()));
  if (!temporary.valid()) {
    throw std::runtime_error("cannot create Prometheus temporary file: " +
                             std::string(std::strerror(errno)));
  }
  const std::filesystem::path temporary_path(writable_template.data());
  bool renamed = false;
  try {
    if (::fchmod(temporary.get(), S_IRUSR | S_IWUSR | S_IRGRP) != 0) {
      throw std::runtime_error("cannot set Prometheus file permissions: " +
                               std::string(std::strerror(errno)));
    }
    write_all(temporary.get(), contents);
    if (::fsync(temporary.get()) != 0) {
      throw std::runtime_error("cannot sync Prometheus temporary file: " +
                               std::string(std::strerror(errno)));
    }
    if (::rename(temporary_path.c_str(), destination.c_str()) != 0) {
      throw std::runtime_error("cannot atomically replace Prometheus output: " +
                               std::string(std::strerror(errno)));
    }
    renamed = true;
    FileDescriptor directory_descriptor(
        ::open(directory.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC));
    if (!directory_descriptor.valid() || ::fsync(directory_descriptor.get()) != 0) {
      throw std::runtime_error("cannot sync Prometheus output directory: " +
                               std::string(std::strerror(errno)));
    }
  } catch (...) {
    if (!renamed) {
      static_cast<void>(::unlink(temporary_path.c_str()));
    }
    throw;
  }
}

void interruptible_sleep(std::chrono::seconds duration) {
  const auto deadline = SteadyClock::now() + duration;
  while (g_stop_requested == 0) {
    const auto now = SteadyClock::now();
    if (now >= deadline) {
      return;
    }
    const auto remaining = deadline - now;
    const auto slice = std::min(
        std::chrono::duration_cast<std::chrono::milliseconds>(remaining),
        std::chrono::milliseconds(200));
    std::this_thread::sleep_for(slice);
  }
}

bool nearly_equal(double left, double right, double tolerance = 1e-9) {
  return std::abs(left - right) <= tolerance;
}

int run_self_test() {
  bool success = true;
  const auto check = [&success](bool condition, std::string_view description) {
    if (!condition) {
      success = false;
      std::cerr << "self-test failed: " << description << '\n';
    }
  };
  check(base64_encode("").empty(), "base64 empty input");
  check(base64_encode("f") == "Zg==", "base64 one byte");
  check(base64_encode("fo") == "Zm8=", "base64 two bytes");
  check(base64_encode("foo") == "Zm9v", "base64 three bytes");
  check(base64_encode("admin:password") == "YWRtaW46cGFzc3dvcmQ=",
        "base64 credentials");

  try {
    check(parse_http_response(
              "HTTP/1.1 200 OK\r\nContent-Length: 2 \t\r\n\r\n{}") == "{}",
          "HTTP Content-Length permits optional whitespace");
    check(parse_http_response(
              "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
              "2\r\n{}\r\n0\r\n\r\n") == "{}",
          "HTTP chunked response");
  } catch (const std::exception& error) {
    check(false, std::string("valid HTTP parser case: ") + error.what());
  }

  try {
    const ServerMetrics metrics = parse_server_metrics(
        R"({"ignored":{"nested":[1,true,null]},"serverfps":59.5,"serverframetime":16.8,"currentplayernum":3,"maxplayernum":16,"uptime":1234})");
    check(nearly_equal(metrics.server_fps, 59.5), "JSON serverfps");
    check(nearly_equal(metrics.server_frame_time, 16.8),
          "JSON serverframetime");
    check(nearly_equal(metrics.current_player_num, 3.0),
          "JSON currentplayernum");
    check(nearly_equal(metrics.max_player_num, 16.0), "JSON maxplayernum");
    check(nearly_equal(metrics.uptime, 1234.0), "JSON uptime");
  } catch (const std::exception& error) {
    check(false, std::string("valid JSON parser case: ") + error.what());
  }
  try {
    static_cast<void>(parse_server_metrics(
        R"({"serverfps":60,"serverframetime":"bad","currentplayernum":0,"maxplayernum":16,"uptime":1})"));
    check(false, "JSON parser rejects a non-numeric required field");
  } catch (const std::exception&) {
  }

  check(nearly_equal(percentile({1.0, 2.0, 3.0, 4.0}, 0.50), 2.5),
        "p50 interpolation");
  check(nearly_equal(percentile({4.0, 1.0, 3.0, 2.0}, 0.95), 3.85),
        "p95 interpolation");
  check(nearly_equal(percentile({7.0}, 0.99), 7.0),
        "single-sample percentile");

  if (success) {
    std::cout << "palworld-observer self-test passed\n";
    return 0;
  }
  return 1;
}

int run_observer(const Config& config) {
  std::vector<HistorySample> history;
  history.reserve(kHistoryLimit);
  std::optional<std::pair<SteadyClock::time_point, std::uint64_t>> previous_cpu;

  while (g_stop_requested == 0) {
    try {
      const std::string password = read_password(config.credential_path);
      const ServerMetrics server =
          parse_server_metrics(fetch_metrics_json(config, password));
      const auto now = SteadyClock::now();
      const CgroupMetrics cgroup = read_cgroup_metrics();
      const double anonymous_memory_mib =
          static_cast<double>(cgroup.anonymous_memory) / (1024.0 * 1024.0);
      if (history.size() == kHistoryLimit) {
        history.erase(history.begin());
      }
      history.push_back(
          {now, server.server_frame_time, anonymous_memory_mib});
      const DerivedMetrics derived =
          derive_metrics(history, cgroup, previous_cpu, now);
      previous_cpu = std::make_pair(now, cgroup.cpu_usage_usec);

      std::cout << make_json_line(server, cgroup, derived, history.size())
                << std::endl;
      atomic_write(config.output_path,
                   make_prometheus_text(server, cgroup, derived,
                                        history.size()));
    } catch (const std::exception& error) {
      std::cerr << "palworld-observer: observation failed; retrying: "
                << error.what() << '\n';
    }
    interruptible_sleep(config.interval);
  }
  return 0;
}

}  // namespace

int main(int argc, char* argv[]) {
  if (argc == 2 && std::string_view(argv[1]) == "--self-test") {
    return run_self_test();
  }
  if (argc != 1) {
    std::cerr << "usage: palworld-observer [--self-test]\n";
    return 2;
  }
  try {
    struct sigaction action {};
    action.sa_handler = handle_signal;
    if (::sigemptyset(&action.sa_mask) != 0 ||
        ::sigaction(SIGTERM, &action, nullptr) != 0 ||
        ::sigaction(SIGINT, &action, nullptr) != 0) {
      throw std::runtime_error("cannot install signal handlers: " +
                               std::string(std::strerror(errno)));
    }
    struct sigaction ignore_pipe {};
    ignore_pipe.sa_handler = SIG_IGN;
    if (::sigemptyset(&ignore_pipe.sa_mask) != 0 ||
        ::sigaction(SIGPIPE, &ignore_pipe, nullptr) != 0) {
      throw std::runtime_error("cannot ignore SIGPIPE: " +
                               std::string(std::strerror(errno)));
    }
    return run_observer(load_config());
  } catch (const std::exception& error) {
    std::cerr << "palworld-observer: fatal: " << error.what() << '\n';
    return 1;
  }
}
