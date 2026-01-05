defmodule DeflateTest do
  use ExUnit.Case, async: true
  doctest Deflate

  # ============================================================================
  # Basic Decompression Tests
  # ============================================================================

  describe "inflate/1 - zlib wrapped data" do
    test "decompresses simple string" do
      original = "hello world"
      compressed = :zlib.compress(original)

      assert {:ok, ^original, consumed} = Deflate.inflate(compressed)
      assert consumed == byte_size(compressed)
    end

    test "decompresses empty string" do
      original = ""
      compressed = :zlib.compress(original)

      assert {:ok, ^original, consumed} = Deflate.inflate(compressed)
      assert consumed == byte_size(compressed)
    end

    test "decompresses single byte" do
      original = "x"
      compressed = :zlib.compress(original)

      assert {:ok, ^original, consumed} = Deflate.inflate(compressed)
      assert consumed == byte_size(compressed)
    end

    test "decompresses repeated data (good for compression)" do
      original = String.duplicate("a", 1000)
      compressed = :zlib.compress(original)

      assert {:ok, ^original, consumed} = Deflate.inflate(compressed)
      assert consumed == byte_size(compressed)
    end

    test "decompresses random-ish data (poor compression)" do
      # Data that doesn't compress well
      original = for i <- 1..500, into: "", do: <<rem(i * 7 + 13, 256)>>
      compressed = :zlib.compress(original)

      assert {:ok, ^original, consumed} = Deflate.inflate(compressed)
      assert consumed == byte_size(compressed)
    end

    test "decompresses binary data with all byte values" do
      original = for i <- 0..255, into: "", do: <<i>>
      compressed = :zlib.compress(original)

      assert {:ok, ^original, consumed} = Deflate.inflate(compressed)
      assert consumed == byte_size(compressed)
    end

    test "decompresses large data" do
      original = :crypto.strong_rand_bytes(10_000)
      compressed = :zlib.compress(original)

      assert {:ok, ^original, consumed} = Deflate.inflate(compressed)
      assert consumed == byte_size(compressed)
    end

    test "decompresses data with patterns" do
      # Mix of repeating patterns and unique data
      original = String.duplicate("abcdefgh", 100) <> "unique" <> String.duplicate("xyz", 50)
      compressed = :zlib.compress(original)

      assert {:ok, ^original, consumed} = Deflate.inflate(compressed)
      assert consumed == byte_size(compressed)
    end
  end

  # ============================================================================
  # Raw DEFLATE Tests
  # ============================================================================

  describe "inflate_raw/1 - raw DEFLATE data" do
    test "decompresses raw deflate without zlib header" do
      original = "hello world"
      # Use zlib to compress, then strip header (2 bytes) and trailer (4 bytes)
      compressed = :zlib.compress(original)
      # Strip zlib wrapper: 2 byte header, 4 byte adler32 trailer
      raw_len = byte_size(compressed) - 6
      raw_deflate = binary_part(compressed, 2, raw_len)

      assert {:ok, ^original, _consumed} = Deflate.inflate_raw(raw_deflate)
    end

    test "returns bytes consumed for streaming parsing" do
      original = "test data"
      compressed = :zlib.compress(original)
      raw_len = byte_size(compressed) - 6
      raw_deflate = binary_part(compressed, 2, raw_len)

      # Append extra bytes that shouldn't be consumed
      extra_data = "EXTRA_DATA_NOT_COMPRESSED"
      data_with_extra = raw_deflate <> extra_data

      assert {:ok, ^original, consumed} = Deflate.inflate_raw(data_with_extra)
      # Verify we only consumed the deflate data, not the extra
      assert consumed == raw_len
    end
  end

  # ============================================================================
  # Byte Consumption Tracking Tests (Critical for git pack files)
  # ============================================================================

  describe "byte consumption tracking" do
    test "tracks exact bytes consumed with zlib wrapper" do
      data = "some data to compress"
      compressed = :zlib.compress(data)

      assert {:ok, ^data, consumed} = Deflate.inflate(compressed)
      assert consumed == byte_size(compressed)
    end

    test "can parse multiple concatenated zlib streams" do
      # This is the key use case for git pack files
      data1 = "first object"
      data2 = "second object"
      data3 = "third object"

      compressed1 = :zlib.compress(data1)
      compressed2 = :zlib.compress(data2)
      compressed3 = :zlib.compress(data3)

      # Concatenate all compressed data
      all_data = compressed1 <> compressed2 <> compressed3

      # Parse first
      assert {:ok, ^data1, consumed1} = Deflate.inflate(all_data)
      remaining1 = binary_part(all_data, consumed1, byte_size(all_data) - consumed1)

      # Parse second
      assert {:ok, ^data2, consumed2} = Deflate.inflate(remaining1)
      remaining2 = binary_part(remaining1, consumed2, byte_size(remaining1) - consumed2)

      # Parse third
      assert {:ok, ^data3, consumed3} = Deflate.inflate(remaining2)

      # Verify we consumed everything
      assert consumed1 + consumed2 + consumed3 == byte_size(all_data)
    end

    test "handles data followed by non-compressed bytes" do
      data = "compressed part"
      compressed = :zlib.compress(data)
      trailer = <<1, 2, 3, 4, 5>>
      combined = compressed <> trailer

      assert {:ok, ^data, consumed} = Deflate.inflate(combined)
      assert consumed == byte_size(compressed)
      assert binary_part(combined, consumed, byte_size(trailer)) == trailer
    end
  end

  # ============================================================================
  # Comparison with :zlib Tests
  # ============================================================================

  describe "compatibility with Erlang :zlib" do
    test "matches :zlib output for various inputs" do
      inputs = [
        "",
        "a",
        "hello",
        "hello world",
        String.duplicate("x", 100),
        String.duplicate("abc", 100),
        :crypto.strong_rand_bytes(100),
        :crypto.strong_rand_bytes(1000),
        # All printable ASCII
        for(c <- 32..126, into: "", do: <<c>>),
        # Binary with nulls
        <<0, 1, 2, 0, 0, 3, 4, 0, 5>>
      ]

      for input <- inputs do
        compressed = :zlib.compress(input)
        assert {:ok, result, _} = Deflate.inflate(compressed)
        assert result == input, "Mismatch for input: #{inspect(input)}"
      end
    end

    test "handles compression level variations" do
      data = String.duplicate("test pattern ", 100)

      # Test with different data sizes that might result in different block types
      test_cases = [
        data,
        String.duplicate("a", 50),
        :crypto.strong_rand_bytes(200),
        String.duplicate("abcdefghij", 100)
      ]

      for test_data <- test_cases do
        compressed = :zlib.compress(test_data)

        assert {:ok, ^test_data, _} = Deflate.inflate(compressed),
               "Failed for data: #{inspect(test_data, limit: 50)}"
      end
    end
  end

  # ============================================================================
  # Error Handling Tests
  # ============================================================================

  describe "error handling" do
    test "returns error for truncated data" do
      assert {:error, :truncated} = Deflate.inflate(<<>>)
      assert {:error, :truncated} = Deflate.inflate(<<0x78>>)
    end

    test "returns error for invalid zlib header" do
      # Invalid compression method (not 8)
      assert {:error, {:invalid_compression_method, _}} = Deflate.inflate(<<0x00, 0x00>>)
    end

    test "returns error for invalid header checksum" do
      # Valid CM but invalid checksum
      assert {:error, :invalid_header_checksum} = Deflate.inflate(<<0x78, 0x00>>)
    end

    test "returns error for incomplete raw deflate" do
      # Just a partial block header
      assert {:error, _} = Deflate.inflate_raw(<<0b00000001>>)
    end
  end

  # ============================================================================
  # Block Type Tests
  # ============================================================================

  describe "block types" do
    test "handles stored (uncompressed) blocks" do
      # DEFLATE reads bits LSB-first within each byte
      # For stored block: BFINAL=1, BTYPE=00
      # Byte layout (LSB first): bit0=BFINAL=1, bit1-2=BTYPE=00, bits3-7=padding=0
      # = 0b00000001 = 0x01
      data = "hello"
      len = byte_size(data)
      nlen = Bitwise.bxor(len, 0xFFFF)

      # 0x01 = BFINAL=1, BTYPE=00 in LSB-first order
      stored_block =
        <<0x01>> <>
          <<len::little-16, nlen::little-16>> <>
          data

      assert {:ok, ^data, _} = Deflate.inflate_raw(stored_block)
    end

    test "handles fixed Huffman blocks" do
      # Most short strings use fixed Huffman
      for str <- ["a", "ab", "abc", "test", "hello world"] do
        compressed = :zlib.compress(str)
        assert {:ok, ^str, _} = Deflate.inflate(compressed)
      end
    end

    test "handles dynamic Huffman blocks" do
      # Longer data with specific patterns often uses dynamic Huffman
      # because it can be more efficient for the actual data distribution
      data = String.duplicate("dynamic huffman test pattern ", 50)
      compressed = :zlib.compress(data)

      assert {:ok, ^data, _} = Deflate.inflate(compressed)
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "edge cases" do
    test "handles back-references that overlap with output" do
      # LZ77 can reference data that's being written (run-length encoding)
      # e.g., "aaa" could be encoded as 'a' followed by copy 1 byte back, 2 times
      data = String.duplicate("a", 100)
      compressed = :zlib.compress(data)

      assert {:ok, ^data, _} = Deflate.inflate(compressed)
    end

    test "handles maximum back-reference distance" do
      # Create data with references at various distances
      data = String.duplicate("x", 1000) <> "unique" <> String.duplicate("x", 1000)
      compressed = :zlib.compress(data)

      assert {:ok, ^data, _} = Deflate.inflate(compressed)
    end

    test "handles data with many unique bytes" do
      # This tests the literal path heavily
      data = for i <- 0..255, into: "", do: <<i, i, i>>
      compressed = :zlib.compress(data)

      assert {:ok, ^data, _} = Deflate.inflate(compressed)
    end

    test "handles very long repeated sequences" do
      # Test maximum length codes
      data = String.duplicate("ab", 10_000)
      compressed = :zlib.compress(data)

      assert {:ok, ^data, _} = Deflate.inflate(compressed)
    end
  end

  # ============================================================================
  # Streaming API Tests
  # ============================================================================

  describe "inflate_stream/3 - streaming decompression" do
    test "streams to SHA-256 hasher" do
      original = "hello world, this is streaming test data"
      compressed = :zlib.compress(original)

      # Initialize hasher
      hasher = :crypto.hash_init(:sha256)

      # Stream decompress directly to hasher
      {:ok, final_hasher, consumed} =
        Deflate.inflate_stream(compressed, hasher, fn chunk, h ->
          :crypto.hash_update(h, chunk)
        end)

      # Compare with expected hash
      expected_hash = :crypto.hash(:sha256, original)
      result_hash = :crypto.hash_final(final_hasher)

      assert result_hash == expected_hash
      assert consumed == byte_size(compressed)
    end

    test "streams with list accumulator" do
      original = "test data for streaming"
      compressed = :zlib.compress(original)

      # Collect chunks in reverse order
      {:ok, chunks, _consumed} =
        Deflate.inflate_stream(compressed, [], fn chunk, acc ->
          [chunk | acc]
        end)

      # Combine and verify
      result = chunks |> Enum.reverse() |> IO.iodata_to_binary()
      assert result == original
    end

    test "tracks bytes consumed correctly" do
      data = "streaming byte tracking test"
      compressed = :zlib.compress(data)

      {:ok, _acc, consumed} =
        Deflate.inflate_stream(compressed, nil, fn _chunk, acc -> acc end)

      assert consumed == byte_size(compressed)
    end

    test "handles concatenated streams" do
      data1 = "first stream"
      data2 = "second stream"

      compressed1 = :zlib.compress(data1)
      compressed2 = :zlib.compress(data2)
      combined = compressed1 <> compressed2

      # Parse first stream
      {:ok, chunks1, consumed1} =
        Deflate.inflate_stream(combined, [], fn chunk, acc -> [chunk | acc] end)

      result1 = chunks1 |> Enum.reverse() |> IO.iodata_to_binary()
      assert result1 == data1

      # Parse second stream from remaining data
      remaining = binary_part(combined, consumed1, byte_size(combined) - consumed1)

      {:ok, chunks2, _consumed2} =
        Deflate.inflate_stream(remaining, [], fn chunk, acc -> [chunk | acc] end)

      result2 = chunks2 |> Enum.reverse() |> IO.iodata_to_binary()
      assert result2 == data2
    end

    test "handles large data with chunked flushing" do
      # Large enough to trigger multiple flushes
      original = :crypto.strong_rand_bytes(50_000)
      compressed = :zlib.compress(original)

      hasher = :crypto.hash_init(:sha256)

      {:ok, final_hasher, _consumed} =
        Deflate.inflate_stream(compressed, hasher, fn chunk, h ->
          :crypto.hash_update(h, chunk)
        end)

      expected = :crypto.hash(:sha256, original)
      result = :crypto.hash_final(final_hasher)

      assert result == expected
    end

    test "handles data with back-references across flush boundaries" do
      # Highly repetitive data that compresses well and uses back-references
      original = String.duplicate("abcdefgh", 10_000)
      compressed = :zlib.compress(original)

      {:ok, chunks, _consumed} =
        Deflate.inflate_stream(compressed, [], fn chunk, acc -> [chunk | acc] end)

      result = chunks |> Enum.reverse() |> IO.iodata_to_binary()
      assert result == original
    end

    test "returns error for truncated data" do
      assert {:error, :truncated} = Deflate.inflate_stream(<<>>, nil, fn _, a -> a end)
      assert {:error, :truncated} = Deflate.inflate_stream(<<0x78>>, nil, fn _, a -> a end)
    end
  end

  describe "inflate_raw_stream/3 - raw streaming decompression" do
    test "streams raw DEFLATE data" do
      original = "raw deflate streaming test"
      compressed = :zlib.compress(original)
      # Strip zlib wrapper
      raw_len = byte_size(compressed) - 6
      raw_deflate = binary_part(compressed, 2, raw_len)

      {:ok, chunks, _consumed} =
        Deflate.inflate_raw_stream(raw_deflate, [], fn chunk, acc -> [chunk | acc] end)

      result = chunks |> Enum.reverse() |> IO.iodata_to_binary()
      assert result == original
    end

    test "tracks raw bytes consumed for concatenated parsing" do
      original = "test data"
      compressed = :zlib.compress(original)
      raw_len = byte_size(compressed) - 6
      raw_deflate = binary_part(compressed, 2, raw_len)

      extra_data = "EXTRA_DATA"
      data_with_extra = raw_deflate <> extra_data

      {:ok, _chunks, consumed} =
        Deflate.inflate_raw_stream(data_with_extra, [], fn chunk, acc -> [chunk | acc] end)

      assert consumed == raw_len
    end
  end

  # ============================================================================
  # Performance Baseline Tests
  # ============================================================================

  describe "performance" do
    @tag :performance
    test "decompresses 1MB in reasonable time" do
      data = :crypto.strong_rand_bytes(1_000_000)
      compressed = :zlib.compress(data)

      {time_us, {:ok, result, _}} = :timer.tc(fn -> Deflate.inflate(compressed) end)

      assert result == data
      # Should complete in under 10 seconds (very generous for pure Elixir)
      assert time_us < 10_000_000, "Took #{time_us / 1_000_000}s"
    end
  end
end
