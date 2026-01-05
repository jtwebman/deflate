# Benchmarks comparing pure Elixir Deflate vs Erlang :zlib NIF
#
# Run with: mix run bench/inflate_bench.exs

defmodule DeflateBench do
  @moduledoc """
  Benchmark comparing pure Elixir DEFLATE decompression vs Erlang :zlib NIF.

  The :zlib module uses C NIFs and will be significantly faster.
  The pure Elixir implementation trades speed for:
  - Exact byte consumption tracking (critical for git pack files)
  - Portability (no C dependencies)
  - Debuggability
  """

  def run do
    IO.puts("\n=== Deflate Benchmark: Pure Elixir vs :zlib NIF ===\n")

    # Generate test data of various sizes
    small_data = generate_text_data(100)
    medium_data = generate_text_data(10_000)
    large_data = generate_text_data(100_000)

    # Random data (compresses poorly)
    random_small = :crypto.strong_rand_bytes(100)
    random_medium = :crypto.strong_rand_bytes(10_000)
    random_large = :crypto.strong_rand_bytes(100_000)

    # Pre-compress all data
    inputs = %{
      "text 100B" => :zlib.compress(small_data),
      "text 10KB" => :zlib.compress(medium_data),
      "text 100KB" => :zlib.compress(large_data),
      "random 100B" => :zlib.compress(random_small),
      "random 10KB" => :zlib.compress(random_medium),
      "random 100KB" => :zlib.compress(random_large)
    }

    Benchee.run(
      %{
        "Deflate (pure Elixir)" => fn input -> Deflate.inflate(input) end,
        ":zlib NIF" => fn input -> :zlib.uncompress(input) end
      },
      inputs: inputs,
      time: 5,
      warmup: 2,
      memory_time: 2,
      formatters: [
        Benchee.Formatters.Console
      ]
    )

    IO.puts("\n=== Byte Tracking Feature (unique to pure Elixir) ===\n")
    demonstrate_byte_tracking()
  end

  defp generate_text_data(size) do
    # Generate compressible text data
    words = ~w(the quick brown fox jumps over lazy dog hello world elixir erlang beam)

    Stream.cycle(words)
    |> Stream.take(div(size, 5))
    |> Enum.join(" ")
    |> binary_part(0, min(size, size))
  end

  defp demonstrate_byte_tracking do
    # This demonstrates the key feature of the pure Elixir implementation
    data1 = "first compressed stream"
    data2 = "second compressed stream"
    data3 = "third compressed stream"

    compressed1 = :zlib.compress(data1)
    compressed2 = :zlib.compress(data2)
    compressed3 = :zlib.compress(data3)

    # Concatenate multiple zlib streams (like git pack files)
    combined = compressed1 <> compressed2 <> compressed3

    IO.puts("Parsing multiple concatenated zlib streams (like git pack files):")
    IO.puts("  Combined data size: #{byte_size(combined)} bytes")
    IO.puts("")

    # Parse each stream and track consumption
    {:ok, result1, consumed1} = Deflate.inflate(combined)
    remaining1 = binary_part(combined, consumed1, byte_size(combined) - consumed1)

    {:ok, result2, consumed2} = Deflate.inflate(remaining1)
    remaining2 = binary_part(remaining1, consumed2, byte_size(remaining1) - consumed2)

    {:ok, result3, consumed3} = Deflate.inflate(remaining2)

    IO.puts("  Stream 1: \"#{result1}\" (consumed #{consumed1} bytes)")
    IO.puts("  Stream 2: \"#{result2}\" (consumed #{consumed2} bytes)")
    IO.puts("  Stream 3: \"#{result3}\" (consumed #{consumed3} bytes)")
    IO.puts("")
    IO.puts("  Total consumed: #{consumed1 + consumed2 + consumed3} bytes")
    IO.puts("  Expected: #{byte_size(combined)} bytes")
    IO.puts("")
    IO.puts("This byte tracking is impossible with :zlib.uncompress/1!")
    IO.puts("")
  end
end

DeflateBench.run()
